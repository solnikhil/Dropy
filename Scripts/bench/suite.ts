#!/usr/bin/env bun
import { readdirSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { evaluate, comparable, parseOptions, profiles, scenarios, type Run } from "./suite/model";
import { preflight, prepare, resultRoot, runSuite } from "./suite/runtime";
import { summarize, fmt } from "./stats";
import { sealEvidence, verifyEvidence, verifyReferencedEvidence } from "./suite/evidence";

async function report(path: string) {
  await verifyEvidence(resolve(path, ".."));
  const run = await Bun.file(path).json() as Run;
  verifyReferencedEvidence(resolve(path, ".."), run);
  const evaluation = evaluate(run);
  const lines = [`# Dropy benchmark ${run.id}`, "", `**${evaluation.passed ? "PASS" : "NOT PASSED"} — ${evaluation.qualification}**`, "",
    `Profile: ${run.options.profile}. Commit: ${run.provenance.commit ?? "unavailable"}. Build: ${run.provenance.buildMode ?? "unavailable"}.`,
    "", "Cold = first opening in a fresh Dropy process; two initial openings are excluded from warm latency. p95 below 20 samples is diagnostic only. CPU 100% = one logical core. Memory is physical footprint where available (raw rows identify RSS fallback).",
    "", "Input latency measures synthetic event posting to fixture dispatch, not input-to-photon latency. Close latency is externally observed and includes command/poll overhead. Synthetic fixture success does not establish third-party compatibility or user demand.",
    "", "| Scenario | Outcome | Detail |", "|---|---|---|"];
  for (const scenario of run.options.scenarios) { const o = run.outcomes[scenario]; lines.push(`| ${scenario} | ${o?.status ?? "not-run"} | ${(o?.reason ?? "").replaceAll("|", "/").replaceAll("\n", " ")} |`); }
  lines.push("", "| Scenario | Metric | n | p50 | p95 | max | mean |", "|---|---|---:|---:|---:|---:|---:|");
  for (const [scenario, o] of Object.entries(run.outcomes)) for (const [metric, values] of Object.entries(o!.metrics)) {
    const s = summarize(values); lines.push(`| ${scenario} | ${metric} | ${s.n} | ${fmt(s.p50)} | ${fmt(s.p95)} | ${fmt(s.max)} | ${fmt(s.mean)} |`);
  }
  lines.push("", "## Gates", "");
  for (const c of evaluation.checks) lines.push(`- ${c.passed ? "PASS" : "FAIL"}: ${c.name} — ${c.detail}`);
  lines.push("", "Raw evidence is stored beside result.json, including command replies, event sequences, resource samples and restoration snapshots. The JSON preserves failures and unrun scenarios; none are treated as passing.");
  await Bun.write(join(resolve(path, ".."), "report.md"), lines.join("\n") + "\n");
  console.log(`${evaluation.passed ? "PASS" : "NOT PASSED"}: ${evaluation.qualification}`);
  for (const c of evaluation.checks.filter(c => !c.passed)) console.log(`  FAIL ${c.name}: ${c.detail}`);
  console.log(`Report: ${join(resolve(path, ".."), "report.md")}`);
  return evaluation.passed;
}
function latest() {
  try { return readdirSync(resultRoot).sort().at(-1); } catch { return undefined; }
}
const [command = "plan", ...args] = process.argv.slice(2);
try {
  switch (command) {
    case "plan": {
      const options = parseOptions(args);
      console.log(JSON.stringify({ ...options, warmupOpenings: 2, inputRates: options.profile === "smoke" ? [10] : [10, 30, 60, 120],
        inputKinds: ["typing", "repeat", "chord"], targets: "disposable AppKit fixture and decoy; separate disposable fullscreen backdrop", build: "optimized -O",
        notes: ["Live runs require an idle, unlocked Mac, Accessibility and Dropy's Screen Recording grant.", "Missing measurements and unfinished cleanup fail the run.", "Smoke results never qualify a release.", "No third-party compatibility or demand claims are inferred."] }, null, 2)); break;
    }
    case "build": await prepare(); break;
    case "preflight": console.log(JSON.stringify(await preflight(), null, 2)); break;
    case "run": {
      const options = parseOptions(args);
      const file = await runSuite(options);
      if (!process.env.DROPY_BENCH_RESULT_POINTER) throw new Error("Missing shell-owned result pointer");
      await Bun.write(process.env.DROPY_BENCH_RESULT_POINTER, file); break;
    }
    case "finalize": {
      if (!args[0]) throw new Error("finalize requires a result path");
      const run = await Bun.file(args[0]).json() as Run;
      for (const outcome of Object.values(run.outcomes)) if (outcome) outcome.evidence = outcome.evidence.map(path => path.startsWith("/") ? relative(resolve(args[0], ".."), path) : path);
      run.cleanup.push({ name: "preferences restored and desktop lock released", passed: args[1] === "0", detail: args[1] === "0" ? "device_session_end succeeded" : "device_session_end failed; durable backup retained" });
      await Bun.write(args[0], JSON.stringify(run, null, 2) + "\n");
      await sealEvidence(resolve(args[0], ".."));
      process.exit(await report(args[0]) ? 0 : 1);
    }
    case "check": {
      const recent = latest();
      const file = args[0] ?? (recent ? join(resultRoot, recent, "result.json") : undefined);
      if (!file) throw new Error("No results; run bun run bench first");
      process.exit(await report(file) ? 0 : 1);
    }
    case "compare": {
      if (args.length !== 2) throw new Error("compare requires two result.json paths");
      const [a, b] = await Promise.all(args.map(path => Bun.file(path).json() as Promise<Run>));
      await Promise.all(args.map(path => verifyEvidence(resolve(path, ".."))));
      [a, b].forEach((run, i) => verifyReferencedEvidence(resolve(args[i], ".."), run));
      if (!comparable(a, b)) throw new Error("Incompatible runs: machine, OS, displays, power, fixture, build configuration and workload must match");
      if (!evaluate(a).passed || !evaluate(b).passed) throw new Error("Cannot use an incomplete/failed run as a performance baseline");
      let regressed = false;
      for (const scenario of a.options.scenarios) for (const [metric, before] of Object.entries(a.outcomes[scenario]!.metrics)) {
        const after = b.outcomes[scenario]?.metrics[metric]; if (!after?.length || !before.length) continue;
        const old = summarize(before).p95!, now = summarize(after).p95!;
        const regression = metric === "warmOpenMs" && now > old * 1.25 && now - old > 40;
        regressed ||= regression;
        console.log(`${regression ? "REGRESSION" : "compare"} ${scenario}.${metric}.p95 ${fmt(old)} -> ${fmt(now)} (n=${before.length}/${after.length})`);
      }
      process.exit(regressed ? 1 : 0);
    }
    case "list":
      for (const entry of readdirSync(resultRoot).sort()) console.log(join(resultRoot, entry, "result.json")); break;
    default: throw new Error("Commands: plan, build, preflight, check, compare, list. Use bun run bench for a live run.");
  }
} catch (error) { console.error(String(error)); process.exit(2); }
