#!/usr/bin/env bun
// Dropy benchmark: measures a build on this Mac, saves the numbers with the version
// they came from, and checks them against budgets and earlier runs.
//
//   bun run bench                     build, measure every scenario, save, check
//   bun run bench -- --cycles 8 --style rapid --no-build --only native,pinned
//   bun run bench:check [result.json] check a result (default: the newest) against
//                                     docs/benchmarks/budgets.json and the previous
//                                     result from this Mac
//   bun run bench:compare [a] [b]     side by side (default: the two newest)
//   bun run bench:list                saved results
//
// Scenarios (each runs Dropy's development cycle driver, DROPY_DEBUG_CYCLES, against a
// scratch TextEdit document; nothing of the person's is opened or moved):
//   native   Full App, direct open, Native size: open → docked, close → back home
//   pinned   the same app pinned and kept ready on the Stage
//   preview  Preview only: open → first live frame
//   fullscreen  pinned, opened over a scratch image shown full screen in Preview: Live
//            mode (the window streamed from the Stage)
//   idle     Dropy running with the overlay closed: CPU and memory
//
// Validity: the run refuses to start while the screen is locked and is discarded if it
// locks or capture is suspended part way (measurements of a locked Mac mean nothing).
// Keep the Mac awake for it, e.g. `caffeinate -d bun run bench`.
//
// Safety: Dropy's preferences are exported first and imported back afterwards, a
// running Dropy is quit and relaunched, and the scratch document is closed. TextEdit
// comes to the front during the run; don't type while it runs.
import { $ } from "bun";
import { mkdtempSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { fmt, summarize, type Summary } from "./stats";

const repo = resolve(import.meta.dir, "../..");
const app = join(repo, ".build/local/Dropy.app");
const resultsDir = join(repo, "docs/benchmarks/results");
const budgetsPath = join(repo, "docs/benchmarks/budgets.json");
const domain = "org.dropy.app";
const prefsKey = "org.dropy.preferences.v1";

type Scenario = "native" | "pinned" | "preview" | "fullscreen" | "idle";
const allScenarios: Scenario[] = ["native", "pinned", "preview", "fullscreen", "idle"];

interface ScenarioResult {
  openReadyMs?: Summary;
  layoutChanges?: Summary;
  closeHomeMs?: Summary;
  firstFrameMs?: Summary;
  stageReadyMs?: Summary;
  cpuPercent: Summary;
  memoryMB: Summary;
  /** Full screen only: openings that came up in Live mode (not a fallback). */
  liveCycles?: number;
  /** Full screen only: openings where the pointer was moved into the app and clicked… */
  pointerChecks?: number;
  /** …and the overlay stayed open, the pointer was handed over and came back. */
  pointerPassed?: number;
  cycles: number;
  readyCycles: number;
}

interface BenchResult {
  version: { commit: string; dirty: boolean; branch: string; describe: string };
  machine: { model: string; macOS: string; build: string };
  date: string;
  settings: { cycles: number; holdMs: number; motionStyle: string };
  scenarios: Partial<Record<Scenario, ScenarioResult>>;
}

// MARK: Arguments

const [command = "run", ...rest] = process.argv.slice(2);
function option(name: string): string | undefined {
  const index = rest.indexOf(`--${name}`);
  return index >= 0 ? rest[index + 1] : undefined;
}
const flag = (name: string) => rest.includes(`--${name}`);
const positional = rest.filter((arg, i) => !arg.startsWith("--") && !rest[i - 1]?.startsWith("--"));

// MARK: Helpers

async function sh(strings: TemplateStringsArray, ...values: unknown[]): Promise<string> {
  return (await $(strings, ...values).quiet().nothrow().text()).trim();
}

async function readPreferences(): Promise<Record<string, unknown>> {
  // The domain as XML: plutil cannot turn data into JSON, and its -extract would read the
  // dots in the key as a path. The value is JSON stored as data (base64 in XML).
  const xml = await sh`defaults export ${domain} - | plutil -convert xml1 -o - -`;
  const escaped = prefsKey.replace(/\./g, "\\.");
  const match = xml.match(new RegExp(`<key>${escaped}</key>\\s*<data>([^<]*)</data>`));
  try {
    return match ? JSON.parse(Buffer.from(match[1].replace(/\s/g, ""), "base64").toString("utf8")) : {};
  } catch {
    return {};
  }
}

async function writePreferences(prefs: Record<string, unknown>) {
  const hex = Buffer.from(JSON.stringify(prefs), "utf8").toString("hex");
  await $`defaults write ${domain} ${prefsKey} -data ${hex}`.quiet();
}

async function dropyPIDs(): Promise<number[]> {
  const out = await sh`pgrep -f ${app + "/Contents/MacOS/Dropy"}`;
  return out ? out.split("\n").map(Number) : [];
}

async function quitDropy() {
  await sh`osascript -e 'tell application id "org.dropy.app" to quit'`;
  for (let i = 0; i < 20 && (await dropyPIDs()).length; i++) await Bun.sleep(150);
  for (const pid of await dropyPIDs()) process.kill(pid);
  await Bun.sleep(300);
}

/** Samples a process's CPU and memory twice a second until it exits or `until` passes. */
async function sample(pid: number, until: number) {
  const cpu: number[] = [];
  const memory: number[] = [];
  while (Date.now() < until) {
    const line = await sh`ps -o %cpu=,rss= -p ${pid}`;
    if (!line) break;
    const [c, rss] = line.split(/\s+/).map(Number);
    cpu.push(c);
    memory.push(Math.round((rss / 1024) * 10) / 10);
    await Bun.sleep(500);
  }
  return { cpu, memory };
}

/** Whether the person's screen is locked (capture is suspended and Accessibility
 *  answers oddly while it is, so nothing measured then means anything). */
async function screenLocked(): Promise<boolean> {
  const json = await sh`ioreg -n Root -d1 -a | plutil -convert json -o - -`;
  try {
    const users: { CGSSessionScreenIsLocked?: boolean; kCGSSessionOnConsoleKey?: boolean }[] =
      JSON.parse(json).IOConsoleUsers ?? [];
    return users.some((user) => user.kCGSSessionOnConsoleKey && user.CGSSessionScreenIsLocked);
  } catch {
    return false;
  }
}

class InvalidRun extends Error {}

/** A scratch image in Preview, full screen, so openings happen over a full-screen app. */
async function enterFullScreen(work: string) {
  const image = join(work, "dropy-fullscreen.png");
  await $`sips -s format png -z 400 600 /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns --out ${image}`.quiet().nothrow();
  await $`open -a Preview ${image}`.quiet();
  await Bun.sleep(1500);
  await $`osascript -e ${`tell application "System Events" to tell process "Preview" to set value of attribute "AXFullScreen" of (first window whose name contains "dropy-fullscreen") to true`}`.quiet().nothrow();
  // The full-screen animation takes about a second.
  await Bun.sleep(2000);
}

async function leaveFullScreen(work: string) {
  await $`osascript -e 'tell application "Preview" to close (every window whose name contains "dropy-fullscreen")'`.quiet().nothrow();
  await Bun.sleep(1500);
}

function numbers(log: string, pattern: RegExp): number[] {
  return [...log.matchAll(pattern)].map((m) => Number(m[1]));
}

// MARK: Running a scenario

async function runScenario(scenario: Scenario, base: Record<string, unknown>, cycles: number, holdMs: number,
                           style: string, work: string): Promise<ScenarioResult> {
  const pinned = scenario === "pinned" || scenario === "fullscreen";
  const prefs: Record<string, unknown> = {
    ...base,
    interaction: scenario === "preview" ? "previewOnly" : "fullApp",
    openBehavior: "direct",
    selectedBundleIdentifier: "com.apple.TextEdit",
    lastUsedBundleIdentifier: "com.apple.TextEdit",
    sizePreset: "nativeSize",
    // Full screen uses the most eager dismissal, which once closed Live mode the
    // moment the pointer went into the app.
    dismissBehavior: scenario === "fullscreen" ? "pointerLeave" : "manual",
    motionStyle: style,
    keepsPinnedAppReady: pinned,
    pinnedBundleIdentifier: pinned ? "com.apple.TextEdit" : undefined,
  };
  await writePreferences(prefs);
  if (scenario === "fullscreen") await enterFullScreen(work);
  const log = join(work, `${scenario}.log`);
  const idle = scenario === "idle";
  // Full screen adds the pointer exercise (about 2.5 s) to each opening.
  const perCycle = holdMs / 1000 + 2.5 + (scenario === "fullscreen" ? 3 : 0);
  const seconds = idle ? 12 : Math.ceil(4 + cycles * perCycle);
  const env = idle
    ? ["--env", `DROPY_DEBUG_QUIT_AFTER=${seconds}`]
    : ["--env", `DROPY_DEBUG_CYCLES=${cycles},${holdMs}`, "--env", `DROPY_DEBUG_QUIT_AFTER=${seconds}`,
       ...(scenario === "fullscreen" ? ["--env", "DROPY_DEBUG_LIVE_POINTER=1"] : [])];
  await $`open -n --stderr ${log} ${env} ${app}`.quiet();
  let pid = 0;
  for (let i = 0; i < 40 && !pid; i++) {
    await Bun.sleep(100);
    pid = (await dropyPIDs()).at(-1) ?? 0;
  }
  // The idle scenario samples after launch has settled; the others throughout.
  if (idle) await Bun.sleep(3000);
  const usage = pid ? await sample(pid, Date.now() + (seconds + 4) * 1000) : { cpu: [], memory: [] };
  for (let i = 0; i < 40 && (await dropyPIDs()).length; i++) await Bun.sleep(250);
  if (scenario === "fullscreen") await leaveFullScreen(work);
  const text = await Bun.file(log).text().catch(() => "");
  if (await screenLocked()) throw new InvalidRun(`the screen locked during the ${scenario} scenario`);
  if (/status=\[[^\]]*suspended/.test(text)) {
    throw new InvalidRun(`capture was suspended during the ${scenario} scenario (screen locked or display asleep)`);
  }
  const ready = numbers(text, /Dropy timing: ready mode=\w+ ms=([\d.]+)/g);
  const result: ScenarioResult = {
    cycles: idle ? 0 : cycles,
    readyCycles: ready.length,
    cpuPercent: summarize(usage.cpu),
    memoryMB: summarize(usage.memory),
  };
  if (scenario === "fullscreen") {
    const live = numbers(text, /Dropy timing: ready mode=(live)/g).length;
    result.liveCycles = live;
    const checks = [...text.matchAll(/Dropy debug live pointer: handedOver=(\w+) kept=(\w+) returned=(\w+)/g)];
    result.pointerChecks = checks.length;
    result.pointerPassed = checks.filter((m) => m[1] === "yes" && m[2] === "yes" && m[3] === "yes").length;
  }
  if (!idle) {
    result.openReadyMs = summarize(ready);
    result.layoutChanges = summarize(numbers(text, /Dropy timing: ready .*layoutChanges=(\d+)/g));
  }
  if (scenario === "native" || scenario === "pinned" || scenario === "fullscreen") {
    result.closeHomeMs = summarize(numbers(text, /Dropy timing: closed home=([\d.]+)ms/g));
  }
  if (pinned) result.stageReadyMs = summarize(numbers(text, /Dropy stage: ready .* in (\d+)ms/g));
  if (scenario === "preview") result.firstFrameMs = summarize(numbers(text, /Dropy reveal: firstFrame=([\d.]+)ms/g));
  return result;
}

// MARK: Commands

async function run() {
  const cycles = Number(option("cycles") ?? 6);
  const holdMs = Number(option("hold") ?? 1500);
  const style = option("style") ?? "balanced";
  const only = option("only")?.split(",") as Scenario[] | undefined;
  const scenarios = only ?? allScenarios;

  if (await screenLocked()) {
    console.error("The screen is locked: unlock it and keep it awake (for example `caffeinate -d`) while the benchmark runs.");
    process.exit(2);
  }
  if (!flag("no-build")) {
    console.log("Building…");
    await $`${join(repo, "Scripts/build-local.sh")}`.quiet();
  }
  const work = mkdtempSync(join(tmpdir(), "dropy-bench-"));
  console.log(`Logs in ${work}`);
  const backup = join(work, "prefs-backup.plist");
  const dropyWasRunning = (await dropyPIDs()).length > 0;
  const textEditWasRunning = (await sh`pgrep -x TextEdit`).length > 0;
  const previewWasRunning = (await sh`pgrep -x Preview`).length > 0;
  await $`defaults export ${domain} ${backup}`.quiet().nothrow();
  const base = await readPreferences();
  const document = join(work, "dropy-bench.txt");
  await Bun.write(document, "Dropy benchmark\nThis scratch window is moved into the notch and back.\n");

  const result: BenchResult = {
    version: {
      commit: await sh`git -C ${repo} rev-parse --short HEAD`,
      dirty: (await sh`git -C ${repo} status --porcelain`).length > 0,
      branch: await sh`git -C ${repo} rev-parse --abbrev-ref HEAD`,
      describe: await sh`git -C ${repo} log -1 --format=%s`,
    },
    machine: {
      model: await sh`sysctl -n hw.model`,
      macOS: await sh`sw_vers -productVersion`,
      build: await sh`sw_vers -buildVersion`,
    },
    date: new Date().toISOString(),
    settings: { cycles, holdMs, motionStyle: style },
    scenarios: {},
  };

  let invalid: string | undefined;
  try {
    await quitDropy();
    await $`open -g -a TextEdit ${document}`.quiet();
    await Bun.sleep(2000);
    for (const scenario of scenarios) {
      console.log(`Running ${scenario}…`);
      result.scenarios[scenario] = await runScenario(scenario, base, cycles, holdMs, style, work);
      await quitDropy();
    }
  } catch (error) {
    if (!(error instanceof InvalidRun)) throw error;
    invalid = error.message;
  } finally {
    await $`defaults import ${domain} ${backup}`.quiet().nothrow();
    const name = basename(document);
    await $`osascript -e ${`tell application "TextEdit" to close (every document whose name is "${name}") saving no`}`.quiet().nothrow();
    if (!previewWasRunning) await $`osascript -e 'tell application "Preview" to quit'`.quiet().nothrow();
    if (!textEditWasRunning) await $`osascript -e 'tell application "TextEdit" to quit'`.quiet().nothrow();
    if (dropyWasRunning) await $`open ${app}`.quiet().nothrow();
  }

  if (invalid) {
    console.error(`\nDiscarded: ${invalid}. Nothing was saved; run it again with the Mac awake and unlocked.`);
    process.exit(2);
  }
  const stamp = result.date.replace(/[:.]/g, "-").slice(0, 19);
  const file = join(resultsDir, `${stamp}-${result.version.commit}${result.version.dirty ? "-dirty" : ""}.json`);
  await Bun.write(file, JSON.stringify(result, null, 2) + "\n");
  console.log(`\nSaved ${file.replace(repo + "/", "")}\n`);
  printResult(result);
  console.log("");
  process.exit(await check(file) ? 0 : 1);
}

function printResult(result: BenchResult) {
  console.log(`${result.version.commit}${result.version.dirty ? " (uncommitted changes)" : ""} · ${result.machine.model} · macOS ${result.machine.macOS} · ${result.settings.motionStyle}`);
  const rows: string[][] = [["Scenario", "Metric", "p50", "p95", "max", "mean", "n"]];
  for (const [scenario, values] of Object.entries(result.scenarios)) {
    for (const [metric, summary] of Object.entries(values ?? {})) {
      if (typeof summary !== "object") continue;
      const s = summary as Summary;
      rows.push([scenario, metric, fmt(s.p50), fmt(s.p95), fmt(s.max), fmt(s.mean), String(s.n)]);
    }
  }
  const widths = rows[0].map((_, i) => Math.max(...rows.map((r) => r[i].length)));
  for (const row of rows) console.log(row.map((cell, i) => cell.padEnd(widths[i])).join("  "));
}

async function resultFiles(): Promise<string[]> {
  return readdirSync(resultsDir).filter((f) => f.endsWith(".json")).sort().map((f) => join(resultsDir, f));
}

async function load(path: string): Promise<BenchResult> {
  return JSON.parse(await Bun.file(path).text());
}

function metric(result: BenchResult, path: string): number | null {
  // "native.openReadyMs.p95"
  const [scenario, name, stat] = path.split(".");
  const summary = (result.scenarios as Record<string, Record<string, Summary>>)[scenario]?.[name];
  return summary ? ((summary as unknown as Record<string, number | null>)[stat] ?? null) : null;
}

/** Budgets, then regressions against the previous result from the same Mac. */
async function check(path?: string): Promise<boolean> {
  const files = await resultFiles();
  const file = path ? resolve(path) : files.at(-1);
  if (!file) {
    console.error("No benchmark results yet: run `bun run bench`.");
    return false;
  }
  const result = await load(file);
  const budgets: Record<string, { max?: number; min?: number; note?: string }> = JSON.parse(await Bun.file(budgetsPath).text());
  let ok = true;
  console.log(`Checking ${basename(file)} against budgets`);
  for (const [path, budget] of Object.entries(budgets)) {
    const value = metric(result, path);
    if (value === null) {
      console.log(`  -     ${path}: not measured`);
      continue;
    }
    const pass = (budget.max === undefined || value <= budget.max) && (budget.min === undefined || value >= budget.min);
    ok &&= pass;
    const limit = budget.max !== undefined ? `≤ ${budget.max}` : `≥ ${budget.min}`;
    console.log(`  ${pass ? "PASS" : "FAIL"}  ${path} = ${fmt(value)} (${limit})${budget.note && !pass ? ` · ${budget.note}` : ""}`);
  }
  for (const [scenario, values] of Object.entries(result.scenarios)) {
    if (values && values.cycles > 0 && values.readyCycles < values.cycles) {
      ok = false;
      console.log(`  FAIL  ${scenario}: only ${values.readyCycles} of ${values.cycles} openings became ready`);
    }
    if (values?.liveCycles !== undefined && values.liveCycles < values.cycles) {
      ok = false;
      console.log(`  FAIL  ${scenario}: only ${values.liveCycles} of ${values.cycles} openings used Live mode`);
    }
    if (values?.pointerChecks !== undefined) {
      const pass = values.pointerChecks > 0 && values.pointerPassed === values.pointerChecks;
      ok &&= pass;
      console.log(`  ${pass ? "PASS" : "FAIL"}  ${scenario}: pointer into the app, click, back out: ${values.pointerPassed} of ${values.pointerChecks} kept the overlay open`);
    }
  }
  // Regressions: the previous result measured on the same Mac model and macOS.
  const earlier = (await Promise.all(files.filter((f) => f < file).map(async (f) => ({ f, r: await load(f) }))))
    .filter(({ r }) => r.machine.model === result.machine.model && r.machine.macOS === result.machine.macOS)
    .at(-1);
  if (earlier) {
    console.log(`Against ${basename(earlier.f)} (${earlier.r.version.commit})`);
    for (const path of Object.keys(budgets).filter((p) => p.endsWith("Ms.p50") || p.endsWith("Ms.p95"))) {
      const now = metric(result, path);
      const before = metric(earlier.r, path);
      if (now === null || before === null || before === 0) continue;
      const change = (now - before) / before;
      // Small absolute changes are noise on a busy Mac; flag 25 % and at least 40 ms.
      const regressed = change > 0.25 && now - before > 40;
      ok &&= !regressed;
      console.log(`  ${regressed ? "SLOWER" : "ok    "}  ${path}: ${fmt(before)} → ${fmt(now)} (${change >= 0 ? "+" : ""}${(change * 100).toFixed(0)}%)`);
    }
  }
  console.log(ok ? "\nAll checks passed." : "\nSome checks failed.");
  return ok;
}

async function compare() {
  const files = await resultFiles();
  const [a, b] = positional.length >= 2 ? positional.map((p) => resolve(p)) : files.slice(-2);
  if (!a || !b) return console.error("Need two results: run `bun run bench` twice, or pass two files.");
  const [ra, rb] = [await load(a), await load(b)];
  console.log(`${basename(a)} (${ra.version.commit})  →  ${basename(b)} (${rb.version.commit})\n`);
  const paths = new Set<string>();
  for (const r of [ra, rb]) {
    for (const [scenario, values] of Object.entries(r.scenarios)) {
      for (const [name, s] of Object.entries(values ?? {})) {
        if (typeof s === "object") for (const stat of ["p50", "p95", "mean"]) paths.add(`${scenario}.${name}.${stat}`);
      }
    }
  }
  for (const path of [...paths].sort()) {
    const before = metric(ra, path);
    const after = metric(rb, path);
    if (before === null && after === null) continue;
    const delta = before !== null && after !== null ? after - before : null;
    console.log(`${path.padEnd(32)} ${fmt(before).padStart(8)} → ${fmt(after).padStart(8)}  ${delta === null ? "" : (delta >= 0 ? "+" : "") + fmt(delta)}`);
  }
}

async function list() {
  for (const file of await resultFiles()) {
    const r = await load(file);
    console.log(`${basename(file)}  ${r.version.commit}${r.version.dirty ? "*" : " "}  ${r.machine.model}  macOS ${r.machine.macOS}  ${r.version.describe}`);
  }
}

switch (command) {
  case "run": await run(); break;
  case "check": process.exit(await check(positional[0]) ? 0 : 1);
  case "compare": await compare(); break;
  case "list": await list(); break;
  default:
    console.error(`unknown command ${command}: run | check | compare | list`);
    process.exit(2);
}
