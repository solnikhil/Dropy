import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { homedir } from "node:os";
import { startProbe } from "../probe-process";
import { expectedMode, isCycles, isLive, isPinned, isPreview, sameWindow, validateInput, type Options, type Outcome, type Run, type Scenario } from "./model";

export const repo = resolve(import.meta.dir, "../../..");
export const build = join(repo, ".build/bench-suite");
export const resultRoot = join(repo, ".build/benchmark-results");
const app = join(build, "Dropy.app");
const tool = join(build, "BenchTool");
const domain = "org.dropy.app", prefsKey = "org.dropy.preferences.v1";
const journal = join(homedir(), "Library/Application Support/Dropy/placement-journal.json");
let cancelled = false;
const cancellable = new Set<ReturnType<typeof startProbe>>();
export const hash = (path: string) => createHash("sha256").update(readFileSync(path)).digest("hex");
export function sourceHash(compiledOnly = true): string {
  const files: string[] = [];
  function walk(dir: string) { for (const entry of readdirSync(join(repo, dir)).sort()) { const p = join(dir, entry); if (statSync(join(repo, p)).isDirectory()) walk(p); else files.push(p); } }
  for (const dir of ["Sources", "Resources", "Scripts/bench"]) walk(dir);
  files.push("Scripts/build-local.sh", "Package.swift");
  const h = createHash("sha256");
  for (const file of files.sort()) {
    if (compiledOnly && file.endsWith(".ts")) continue;
    h.update(file).update(readFileSync(join(repo, file)));
  }
  return h.digest("hex");
}
export async function exec(args: string[], timeout = 15000, allowFailure = false): Promise<string> {
  const probe = startProbe(args, timeout);
  // Input tools finish their balanced key-up sequence even after an interrupt.
  const mayCancel = args[0].endsWith("/Sampler");
  if (mayCancel) cancellable.add(probe);
  const result = await probe.result.finally(() => cancellable.delete(probe));
  if (result.timedOut || (!allowFailure && result.exitCode !== 0)) throw new Error(`${args[0]}: ${result.timedOut ? "timed out" : result.stderr.trim() || result.stdout.trim() || `exit ${result.exitCode}`}`);
  return result.stdout.trim();
}
export async function prepare() {
  console.log("Building optimized Dropy and disposable fixtures…");
  const pattern = join(app, "Contents/MacOS/Dropy").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  if ((await exec(["pgrep", "-f", `^${pattern}( |$)`], 5000, true)).length) throw new Error("Optimized benchmark app is running; refuse to replace its executable");
  const before = sourceHash();
  await exec(["/usr/bin/env", `DROPY_BUILD_DIR=${build}`, "DROPY_BUILD_CONFIGURATION=release", join(repo, "Scripts/build-local.sh")], 180000);
  await exec([join(repo, "Scripts/bench/build-suite.sh")], 120000);
  if (before !== sourceHash()) throw new Error("Sources changed during compilation; build receipt refused. Build again after edits settle.");
  await Bun.write(join(build, "build.json"), JSON.stringify({ sourceHash: before, appHash: hash(join(app, "Contents/MacOS/Dropy")), fixtureHash: hash(join(build, "Benchmark-fixture.app/Contents/MacOS/BenchmarkFixture")), buildMode: "release-O" }));
}
async function environment() {
  const value = JSON.parse(await exec([tool, "environment"]));
  const power = await exec(["pmset", "-g", "batt"]);
  value.power = power.includes("'AC Power'") ? "AC" : "battery";
  return value;
}
function validEnvironment(value: any) {
  if (!value.sessionKnown || !value.console || value.locked) throw new Error("Unlocked console session could not be verified");
  if (!value.accessibility) throw new Error("Accessibility is unavailable to the benchmark tool; no permission request was made");
  if (!value.promptsClear) throw new Error("A permission/security prompt is present");
  if (value.thermal >= 2) throw new Error("Thermal pressure is serious or critical");
}
export async function preflight() {
  const value = await environment();
  return { ...value, dropyRunning: (await exec(["pgrep", "-x", "Dropy"], 5000, true)).length > 0, pendingRecovery: await Bun.file(journal).exists() };
}
class Channel {
  pid = 0;
  constructor(readonly directory: string) { mkdirSync(directory, { recursive: true, mode: 0o700 }); }
  async ready() {
    const value = await this.read("ready", 10000);
    if (this.pid && this.pid !== value.pid) throw new Error("Startup reply came from a different process");
    this.pid = value.pid; return value;
  }
  async read(id: string, timeout: number): Promise<any> {
    const file = Bun.file(join(this.directory, `${id}.json`));
    const deadline = performance.now() + timeout;
    while (performance.now() < deadline) {
      if (await file.exists()) return await file.json();
      await Bun.sleep(25);
    }
    throw new Error(`No ${id === "ready" ? "startup" : "command"} reply from ${this.directory}`);
  }
  async command(action: string) {
    const id = randomUUID();
    await exec([tool, "command", this.directory, id, action]);
    const reply = await this.read(id, 4000);
    if (reply.error) throw new Error(reply.error);
    return reply;
  }
}
async function until<T>(get: () => Promise<T>, accept: (value: T) => boolean, description: string, timeout = 10000): Promise<T> {
  const deadline = performance.now() + timeout;
  while (performance.now() < deadline) {
    const value = await get();
    if (accept(value)) return value;
    await Bun.sleep(50);
  }
  throw new Error(`Timed out: ${description}`);
}
async function alive(pid: number) { try { process.kill(pid, 0); return true; } catch { return false; } }
async function launch(channel: Channel, bundle: string, bundleID: string, executable: string, args: string[]) {
  const processArgs = [tool, "process", bundleID, join(bundle, "Contents/MacOS", executable)];
  if (JSON.parse(await exec(processArgs)).length) throw new Error(`Benchmark executable already running: ${bundleID}`);
  await exec(["open", "-n", ...args, bundle]);
  const pids = await until(async () => JSON.parse(await exec(processArgs)) as number[], ids => ids.length > 0, "LaunchServices process registration");
  if (pids.length !== 1) throw new Error("Ambiguous benchmark process ownership");
  channel.pid = pids[0];
}
async function stop(channel: Channel | undefined) {
  if (!channel?.pid || !await alive(channel.pid)) return;
  try {
    await channel.command("quit");
    await until(() => alive(channel.pid), running => !running, "owned process exit", 10000);
  } catch (error) {
    if (await alive(channel.pid)) process.kill(channel.pid, "SIGTERM");
    throw new Error(`Graceful cleanup failed for owned process ${channel.pid}: ${error}; inspect recovery journal`);
  }
}
function addCheck(outcome: Outcome, name: string, passed: boolean, detail: string) {
  outcome.checks.push({ name, passed, detail });
  if (!passed) throw new Error(`${name}: ${detail}`);
}
function add(outcome: Outcome, key: string, value: number) { (outcome.metrics[key] ??= []).push(value); }
async function writePrefs(scenario: Scenario) {
  const prefs = { interaction: isPreview(scenario) ? "previewOnly" : "fullApp", trigger: "shortcut", openBehavior: "direct",
    selectedBundleIdentifier: "org.dropy.benchmarkfixture", lastUsedBundleIdentifier: "org.dropy.benchmarkfixture",
    pinnedBundleIdentifier: isPinned(scenario) ? "org.dropy.benchmarkfixture" : undefined, keepsPinnedAppReady: isPinned(scenario),
    sizePreset: "compact", automaticWindowSize: true, dismissBehavior: "manual", contentMode: "fit", motionStyle: "balanced",
    customAnimation: null, showInDock: false, position: "notch", hidesDock: false, protectsVideo: false, restrictNotchCrossing: false,
    shortcut: { keyCode: 2, modifiers: 6144, display: "⌃⌥D" } };
  await exec(["defaults", "write", domain, prefsKey, "-data", Buffer.from(JSON.stringify(prefs)).toString("hex")]);
}
async function sample(outcome: Outcome, seconds: number, fixture: Channel, dropy: Channel | undefined, directory: string) {
  const ws = (await exec(["pgrep", "-x", "WindowServer"], 5000, true)).split("\n")[0];
  const args = [join(build, "Sampler"), String(seconds), `fixture=${fixture.pid}`, ...(dropy ? [`dropy=${dropy.pid}`] : []), ...(ws ? [`windowserver=${ws}`] : []), "--json"];
  const raw = await exec(args, (seconds + 10) * 1000);
  const file = join(directory, "resources.json");
  await Bun.write(file, raw + "\n"); outcome.evidence.push(file);
  const rows = JSON.parse(raw).samples;
  addCheck(outcome, "thermal pressure", rows.length > 0 && rows.every((row: any) => row.thermal < 2), "no serious/critical pressure throughout sampling");
  for (const row of rows) {
    for (const [label, entry] of Object.entries(row.processes) as [string, any][]) {
      add(outcome, `${label}.cpuPercent`, entry.cpuPercent); add(outcome, `${label}.memoryMB`, entry.memoryMB);
      if (typeof entry.idleWakeupsPerSecond === "number") add(outcome, `${label}.wakeupsPerSecond`, entry.idleWakeupsPerSecond);
    }
    if (typeof row.gpuPercent === "number") add(outcome, "system.gpuPercent", row.gpuPercent);
  }
  for (const label of ["fixture", "dropy", "windowserver"]) {
    const memory = outcome.metrics[`${label}.memoryMB`];
    if (memory && memory.length >= 4) {
      const n = Math.floor(memory.length / 4);
      const mean = (values: number[]) => values.reduce((a, b) => a + b, 0) / values.length;
      add(outcome, `${label}.memoryGrowthMB`, mean(memory.slice(-n)) - mean(memory.slice(0, n)));
    }
  }
}
async function exerciseInput(outcome: Outcome, fixture: Channel, windowID: number, options: Options, directory: string) {
  // Standard typing, fast repeat, and intentionally excessive bursts are labelled separately.
  const rates = options.profile === "smoke" ? [10] : [10, 30, 60, 120];
  for (const kind of ["typing", "repeat", "chord"]) for (const rate of rates) {
    await fixture.command("reset");
    const raw = await exec([tool, "keys", String(fixture.pid), String(windowID), String(options.keys), String(rate), kind], Math.ceil(options.keys / rate * 1000) + 15000);
    const sent = JSON.parse(raw);
    const path = join(directory, `input-${kind}-${rate}.json`);
    await Bun.sleep(300);
    const received = await fixture.command("snapshot");
    await Bun.write(path, JSON.stringify({ rate, kind, sent, received }, null, 2)); outcome.evidence.push(path);
    for (const check of validateInput(sent.events, received.targetEvents, received.decoyEvents)) addCheck(outcome, `${kind}@${rate}: ${check.name}`, check.passed, check.detail);
    const achieved = (options.keys - 1) / (sent.durationMs / 1000);
    addCheck(outcome, `${kind}@${rate}: achieved rate`, achieved >= rate * 0.85, `${achieved.toFixed(1)} groups/s; at least 85% of requested rate`);
    for (const event of received.targetEvents) add(outcome, `${kind}@${rate}.dispatchMs`, event.latencyMs);
    add(outcome, `${kind}@${rate}.actualGroupsPerSecond`, achieved);
    if (cancelled) throw new Error("Benchmark interrupted");
  }
}

export async function runSuite(options: Options): Promise<string> {
  if (!process.env.DROPY_BENCH_SESSION || process.env.DROPY_BENCH_SESSION !== process.env.DROPY_DEVICE_SESSION) throw new Error("Run through Scripts/bench/run-suite.sh to acquire the desktop lock");
  if (options.build) await prepare();
  const receipt = await Bun.file(join(build, "build.json")).json();
  if (receipt.sourceHash !== sourceHash() || receipt.appHash !== hash(join(app, "Contents/MacOS/Dropy"))) throw new Error("Build is stale or replaced; rerun without --no-build");
  const id = new Date().toISOString().replace(/[:.]/g, "-") + "-" + randomUUID().slice(0, 8);
  const directory = join(resultRoot, id); mkdirSync(directory, { recursive: true, mode: 0o700 });
  const run: Run = { schemaVersion: 2, id, date: new Date().toISOString(), options, environment: {}, provenance: {}, outcomes: {}, cleanup: [] };
  const resultFile = join(directory, "result.json");
  const interrupt = () => { cancelled = true; for (const probe of cancellable) probe.stop(); };
  process.on("SIGINT", interrupt); process.on("SIGTERM", interrupt);
  const save = () => Bun.write(resultFile, JSON.stringify(run, null, 2) + "\n");
  console.log(`Evidence: ${directory}`);
  let fixture: Channel | undefined, dropy: Channel | undefined, backdrop: Channel | undefined;
  let baseline: any;
  try {
    run.environment = await preflight(); validEnvironment(run.environment);
    if (run.environment.dropyRunning || run.environment.pendingRecovery || run.environment.fixtureAlreadyRunning) throw new Error("Dropy/fixture is already running or recovery is pending");
    const idleText = await exec(["ioreg", "-c", "IOHIDSystem"]);
    const idle = Number(idleText.match(/"HIDIdleTime"\s*=\s*(\d+)/)?.[1] ?? 0) / 1e9;
    if (idle < 5) throw new Error("Desktop was used during build/preflight; retry --no-build after five idle seconds");
    const hardware = await exec(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"]);
    const uuid = hardware.match(/"IOPlatformUUID"\s*=\s*"([^"]+)"/)?.[1];
    if (!uuid) throw new Error("Cannot identify machine for valid comparisons");
    run.provenance = { ...receipt, machineID: createHash("sha256").update(uuid).digest("hex"),
      commit: await exec(["git", "-C", repo, "rev-parse", "HEAD"]), dirty: (await exec(["git", "-C", repo, "status", "--porcelain"])).length > 0,
      model: await exec(["sysctl", "-n", "hw.model"]), osBuild: await exec(["sw_vers", "-buildVersion"]), arch: process.arch,
      swift: await exec(["swift", "--version"]), bun: Bun.version, harnessHash: sourceHash(false) };
    fixture = new Channel(join(directory, randomUUID()));
    // open's --args must follow the bundle; --env works before it for both app kinds.
    await launch(fixture, join(build, "Benchmark-fixture.app"), "org.dropy.benchmarkfixture", "BenchmarkFixture", ["--env", `DROPY_FIXTURE_CONTROL=${fixture.directory}`]);
    baseline = await fixture.ready();
    await until(() => fixture!.command("snapshot"), s => s.frontmost && s.target.key, "fixture focus");
    baseline = await fixture.command("snapshot");
    if (!baseline.target.spaces.length || !baseline.decoy.spaces.length) throw new Error("Cannot verify fixture desktop ownership");
    for (const scenario of options.scenarios) {
      const outcome: Outcome = { status: "not-run", trials: [], metrics: {}, checks: [], evidence: [] };
      run.outcomes[scenario] = outcome;
      const scenarioDir = join(directory, scenario); mkdirSync(scenarioDir);
      console.log(`Running ${scenario}…`);
      try {
        if (cancelled) throw new Error("Benchmark interrupted");
        validEnvironment(await environment());
        await fixture.command("static"); await fixture.command("focus");
        if (scenario !== "control") {
          await writePrefs(scenario);
          dropy = new Channel(join(scenarioDir, randomUUID()));
          const log = join(scenarioDir, "dropy.log"); outcome.evidence.push(log, dropy.directory);
          const launchedAt = performance.now();
          await launch(dropy, app, domain, "Dropy", ["--stderr", log, "--env", `DROPY_DEBUG_BENCHMARK=${dropy.directory}`]);
          const initial = await dropy.ready();
          add(outcome, "launchObservedMs", performance.now() - launchedAt);
          add(outcome, "stageReadyAtControlStartup", initial.stageReady ? 1 : 0);
          addCheck(outcome, "app permissions", initial.accessibility && initial.screenRecording, "Accessibility and Screen Recording required; no automatic permission requests");
          if (isLive(scenario)) {
            backdrop = new Channel(join(scenarioDir, randomUUID()));
            await launch(backdrop, join(build, "Benchmark-backdrop.app"), "org.dropy.benchmarkbackdrop", "BenchmarkFixture", ["--env", `DROPY_FIXTURE_CONTROL=${backdrop.directory}`, "--env", "DROPY_FIXTURE_BACKDROP=1"]);
            await backdrop.ready(); await backdrop.command("fullscreen");
            await until(() => backdrop!.command("snapshot"), s => s.target.fullscreen && s.frontmost, "disposable fullscreen backdrop");
            await Bun.sleep(1500);
          }
        }
        const opened = async () => {
          const state = await until(() => dropy!.command("snapshot"), s => ["docked", "viewing", "live"].includes(s.state) || s.state.startsWith("failed"), "overlay ready");
          addCheck(outcome, "mode and exact target", state.state === expectedMode(scenario) && state.windowID === baseline.target.windowID, `${state.state} window=${state.windowID}; expected ${expectedMode(scenario)} window=${baseline.target.windowID}`);
          return state;
        };
        const close = async () => {
          const start = performance.now(); await dropy!.command("close");
          await until(async () => ({ app: await dropy!.command("snapshot"), fixture: await fixture!.command("snapshot") }), s => s.app.state === "closed" && (isPinned(scenario) ? s.app.stageOccupied : s.app.pendingPlacements === 0 && sameWindow(baseline.target, s.fixture.target)), "close/restoration");
          return performance.now() - start;
        };
        if (isCycles(scenario)) {
          for (let i = 0; i < options.cycles + 2; i++) {
            if (cancelled) throw new Error("Benchmark interrupted");
            if (isLive(scenario)) await backdrop!.command("focus");
            await dropy!.command("open"); const ready = await opened();
            if (isPreview(scenario)) await until(() => dropy!.command("snapshot"), s => typeof s.firstFrameMs === "number", "first presented frame");
            await Bun.sleep(150);
            const state = await dropy!.command("snapshot");
            const closeMs = await close();
            outcome.trials.push({ iteration: i, warmup: i < 2, mode: state.state, windowID: state.windowID,
              readyMs: state.readyMs, closeObservedMs: closeMs, firstFrameMs: state.firstFrameMs ?? undefined, layoutChanges: state.layoutChanges });
            if (i === 0) add(outcome, "coldOpenMs", state.readyMs);
            if (i >= 2) { add(outcome, "warmOpenMs", state.readyMs); add(outcome, "closeObservedMs", closeMs); if (state.firstFrameMs !== null) add(outcome, "firstFrameMs", state.firstFrameMs); }
          }
          await dropy!.command("open"); await opened();
        } else if (scenario !== "idle" && scenario !== "control" && scenario !== "rapid") {
          await dropy!.command("open"); await opened();
        }
        if (scenario === "staged-idle") await close();
        if (scenario === "recovery") {
          await close();
          const staged = await dropy!.command("snapshot");
          addCheck(outcome, "crash setup", staged.stageOccupied && staged.pendingPlacements > 0 && await Bun.file(journal).exists(), "owned fixture is staged and journal exists before SIGKILL");
          process.kill(dropy!.pid, "SIGKILL");
          await until(() => alive(dropy!.pid), running => !running, "terminated benchmark process");
          dropy = new Channel(join(scenarioDir, randomUUID()));
          outcome.evidence.push(dropy.directory);
          await launch(dropy, app, domain, "Dropy", ["--stderr", join(scenarioDir, "recovery.log"), "--env", `DROPY_DEBUG_BENCHMARK=${dropy.directory}`]);
          await dropy.ready();
          await until(async () => ({ app: await dropy!.command("snapshot"), fixture: await fixture!.command("snapshot") }), s => s.app.pendingPlacements === 0 && sameWindow(baseline.target, s.fixture.target), "crash recovery restores original geometry and Space");
          addCheck(outcome, "crash recovery", true, "restored exact fixture identity, geometry and Space after forced termination");
        }
        if (scenario.endsWith("-active")) await fixture.command("animate");
        if (scenario === "control" || scenario.startsWith("input-")) {
          if (scenario === "control") await fixture.command("focus");
          // No focus repair during overlay input: an incorrect focus handoff must fail.
          await exerciseInput(outcome, fixture, baseline.target.windowID, options, scenarioDir);
        }
        if (scenario === "rapid") {
          for (const delay of [0, 16, 50, 100]) {
            for (let i = 0; i < options.cycles; i++) {
              if (cancelled) throw new Error("Benchmark interrupted");
              const started = performance.now();
              await dropy!.command("open"); if (delay) await Bun.sleep(delay); await dropy!.command("close");
              add(outcome, `rapid@${delay}.actualCycleMs`, performance.now() - started);
            }
            await until(() => dropy!.command("snapshot"), s => s.state === "closed" && s.pendingPlacements === 0, "rapid cancellation settled");
            const restored = await fixture.command("snapshot");
            addCheck(outcome, `rapid ${delay}ms restores`, sameWindow(baseline.target, restored.target) && sameWindow(baseline.decoy, restored.decoy), `${options.cycles} interrupted openings; IPC overhead is additional to requested delay`);
          }
          // Actual global shortcut delivery, with a state acknowledgement after each event.
          await exec([tool, "shortcut"]); await opened();
          await exec([tool, "shortcut"]);
          await until(() => dropy!.command("snapshot"), s => s.state === "closed" && s.pendingPlacements === 0, "shortcut close");
          addCheck(outcome, "global shortcut opens and closes", true, "Control-Option-D through HID/Carbon path");
        }
        await Bun.sleep(2000); // separate launch/input work from the steady-state interval
        if (cancelled) throw new Error("Benchmark interrupted");
        const capturing = isLive(scenario) || isPreview(scenario);
        const captureBefore = capturing ? (await dropy!.command("capture")).capture : undefined;
        await sample(outcome, options.seconds, fixture, dropy, scenarioDir);
        if (dropy) {
          const finalState = await dropy.command("capture");
          const closed = ["idle", "staged-idle", "rapid", "recovery"].includes(scenario);
          addCheck(outcome, "mode survived resource interval", finalState.state === (closed ? "closed" : expectedMode(scenario)) && (closed || finalState.windowID === baseline.target.windowID), `ended in ${finalState.state}, window=${finalState.windowID}`);
          if (capturing) {
            const capture = finalState.capture;
            addCheck(outcome, "capture evidence", capture && captureBefore && capture.presented > 0 && Math.abs(capture.clockOffsetMs) <= 1, "presented frames and valid presentation clock required");
            addCheck(outcome, "capture uninterrupted", !(capture.statuses.suspended > 0) && !(capture.statuses.blank > 0), "no suspended or blank frame statuses");
            const frames = capture.presented - captureBefore.presented;
            add(outcome, "presentedFramesDuringInterval", frames);
            if (scenario.endsWith("-active")) addCheck(outcome, "active content kept presenting", frames >= options.seconds * 20, `${frames} new presented frames over ${options.seconds}s; conservative 20 fps floor`);
            for (const metric of ["frameAgeMs", "callbackToPresentMs", "captureToCallbackMs"]) {
              const values = capture[metric].slice(captureBefore[metric].length);
              outcome.metrics[metric] = values;
              if (scenario.endsWith("-active")) addCheck(outcome, `${metric} valid`, values.length > 0 && values.every((v: number) => Number.isFinite(v) && v >= 0), "raw interval samples; clock-invalid measurements fail");
            }
          }
        }
        const ending = await environment(); validEnvironment(ending);
        addCheck(outcome, "power stable", ending.power === run.environment.power && ending.lowPower === run.environment.lowPower, "power source and low-power mode unchanged");
        addCheck(outcome, "physical displays stable", run.environment.displays.every((d: any) => ending.displays.some((e: any) => JSON.stringify(e) === JSON.stringify(d))), "initial displays retain geometry, scale and refresh rate");
        outcome.status = "passed";
      } catch (error) { outcome.status = "failed"; outcome.reason = String(error); }
      finally {
        try {
          await stop(dropy); dropy = undefined;
          if (backdrop) { await backdrop.command("windowed"); await Bun.sleep(1200); await stop(backdrop); backdrop = undefined; }
          await fixture.command("static");
          const final = await until(() => fixture!.command("snapshot"), s => sameWindow(baseline.target, s.target) && sameWindow(baseline.decoy, s.decoy) && !s.hidden, "both fixture windows restored");
          const path = join(scenarioDir, "restoration.json"); await Bun.write(path, JSON.stringify({ before: baseline, after: final }, null, 2)); outcome.evidence.push(path);
          addCheck(outcome, "restoration including Space", true, "target and decoy geometry/minimization/desktop, app visibility verified");
          addCheck(outcome, "journal empty", !await Bun.file(journal).exists(), "no pending placement after app exit");
        } catch (error) { outcome.status = "failed"; outcome.reason = `${outcome.reason ?? ""} Cleanup: ${error}`; }
      }
      await save();
      if (outcome.status !== "passed") break;
    }
    run.cleanup.push({ name: "source and binary unchanged during measurement", passed: receipt.sourceHash === sourceHash() && run.provenance.harnessHash === sourceHash(false) && receipt.appHash === hash(join(app, "Contents/MacOS/Dropy")), detail: "concurrent source changes invalidate attribution" });
  } catch (error) {
    for (const scenario of options.scenarios) if (!run.outcomes[scenario]) run.outcomes[scenario] = { status: "blocked", reason: String(error), trials: [], metrics: {}, checks: [], evidence: [] };
  } finally {
    for (const [name, channel] of [["Dropy", dropy], ["backdrop", backdrop], ["fixture", fixture]] as const) {
      try { await stop(channel); run.cleanup.push({ name: `${name} cleanup`, passed: true, detail: "owned process stopped or never started" }); }
      catch (error) { run.cleanup.push({ name: `${name} cleanup`, passed: false, detail: String(error) }); }
    }
    // The zsh owner restores preferences from its durable backup after Bun exits.
    for (const scenario of options.scenarios) if (!run.outcomes[scenario]) run.outcomes[scenario] = {
      status: "not-run", reason: "Stopped after an earlier scenario failed", trials: [], metrics: {}, checks: [], evidence: []
    };
    await save();
    process.off("SIGINT", interrupt); process.off("SIGTERM", interrupt);
  }
  console.log(`Saved ${resultFile}`);
  return resultFile;
}
