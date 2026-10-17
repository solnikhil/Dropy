import { describe, expect, test } from "bun:test";
import { comparable, evaluate, parseOptions, sameWindow, validateInput, type Run } from "../Scripts/bench/suite/model";
import { percentile } from "../Scripts/bench/stats";

function valid(): Run {
  return { schemaVersion: 2, id: "test", date: "2026-10-16", options: parseOptions(["--only", "native"]),
    provenance: { machineID: "machine", osBuild: "os", arch: "arm64", buildMode: "release-O", fixtureHash: "fixture" },
    environment: { displays: [{ id: 1, width: 1000 }], power: "AC", lowPower: false },
    outcomes: { native: { status: "passed", evidence: ["raw.json"], checks: [{ name: "restore", passed: true, detail: "verified" }],
      trials: Array.from({ length: 5 }, (_, i) => ({ iteration: i, warmup: false, mode: "docked", windowID: 1, readyMs: 100, closeObservedMs: 50, layoutChanges: 0 })),
      metrics: { coldOpenMs: [150], warmOpenMs: [100, 100, 100, 100, 100], "dropy.cpuPercent": [1, 1, 1, 1, 1], "dropy.memoryMB": [60, 60, 60, 60, 60] } } },
    cleanup: [{ name: "cleanup", passed: true, detail: "restored" }] };
}

describe("benchmark validity gates", () => {
  test("smoke can pass only as smoke", () => { const result = evaluate(valid()); expect(result.passed).toBe(true); expect(result.qualification).toContain("no release"); });
  test("missing scenarios do not turn into passes", () => { const run = valid(); delete run.outcomes.native; expect(evaluate(run).passed).toBe(false); });
  test("missing measurements fail", () => { const run = valid(); delete run.outcomes.native!.metrics.warmOpenMs; expect(evaluate(run).passed).toBe(false); });
  test("a missing resource process cannot be hidden by other samples", () => { const run = valid(); run.outcomes.native!.metrics["dropy.cpuPercent"] = []; expect(evaluate(run).passed).toBe(false); });
  test("nonfinite measurements fail", () => { const run = valid(); run.outcomes.native!.metrics["dropy.cpuPercent"][0] = NaN; expect(evaluate(run).passed).toBe(false); });
  test("fallback mode fails even with good latency", () => { const run = valid(); run.outcomes.native!.trials[0].mode = "viewing"; expect(evaluate(run).passed).toBe(false); });
  test("unfinished and extra cycles fail", () => { for (const n of [4, 6]) { const run = valid(); run.outcomes.native!.trials = Array(n).fill(run.outcomes.native!.trials[0]); expect(evaluate(run).passed).toBe(false); } });
  test("warmups do not satisfy measured cycle count", () => { const run = valid(); run.outcomes.native!.trials[0].warmup = true; expect(evaluate(run).passed).toBe(false); });
  test("insufficient standard samples cannot qualify p95", () => { const run = valid(); run.options.profile = "standard"; expect(evaluate(run).passed).toBe(false); });
  test("cleanup failures invalidate passing performance", () => { const run = valid(); run.cleanup[0].passed = false; expect(evaluate(run).passed).toBe(false); });
  test("unrecorded cleanup fails", () => { const run = valid(); run.cleanup = []; expect(evaluate(run).passed).toBe(false); });
  test("empty evidence fails", () => { const run = valid(); run.outcomes.native!.evidence = []; expect(evaluate(run).passed).toBe(false); });
  test("a correctness failure overrides a passed label", () => { const run = valid(); run.outcomes.native!.checks[0].passed = false; expect(evaluate(run).passed).toBe(false); });
  test("legacy evidence is not promoted", () => { const run = valid(); (run as any).schemaVersion = 1; expect(evaluate(run).passed).toBe(false); });
});

describe("restoration and input", () => {
  const before = { windowID: 42, frame: [100, 100, 500, 320], spaces: [3], minimized: false };
  test("window size tolerance is bounded", () => { expect(sameWindow(before, { ...before, frame: [101, 100, 500, 320] })).toBe(true); expect(sameWindow(before, { ...before, frame: [104, 100, 500, 320] })).toBe(false); });
  test("wrong desktop or unknown Space fails", () => { expect(sameWindow(before, { ...before, spaces: [1] })).toBe(false); expect(sameWindow({ ...before, spaces: [] }, { ...before, spaces: [] })).toBe(false); });
  test("wrong identity and malformed geometry fail", () => { expect(sameWindow(before, { ...before, windowID: 43 })).toBe(false); expect(sameWindow(before, { ...before, frame: [100] })).toBe(false); });
  const events = [1, 2].map((sequence, i) => ({ sequence, kind: i ? "up" : "down", keyCode: 0, repeat: false, shift: false, latencyMs: 1 }));
  test("exact events pass", () => expect(validateInput(events, events, []).every(c => c.passed)).toBe(true));
  test("loss, duplicates, reordering and decoy delivery fail", () => {
    for (const received of [events.slice(1), [...events, events[0]], [...events].reverse()]) expect(validateInput(events, received, []).every(c => c.passed)).toBe(false);
    expect(validateInput(events, events, [events[0]]).every(c => c.passed)).toBe(false);
  });
  test("repeat and modifier corruption fail", () => { for (const change of [{ repeat: true }, { shift: true }]) expect(validateInput(events, [{ ...events[0], ...change }, events[1]], []).every(c => c.passed)).toBe(false); });
  test("empty input cannot pass", () => expect(validateInput([], [], []).every(c => c.passed)).toBe(false));
  test("clock mismatch fails", () => expect(validateInput(events, [{ ...events[0], latencyMs: -1 }, events[1]], []).every(c => c.passed)).toBe(false));
});

describe("configuration and comparisons", () => {
  test("bad options fail before any desktop work", () => { for (const args of [["--cycles", "NaN"], ["--cycles", "0"], ["--seconds", "Infinity"], ["--only", "typo"], ["--only", "native,native"], ["--profile", "nope"], ["--keys"], ["--wat"]]) expect(() => parseOptions(args)).toThrow(); });
  test("same conditions compare", () => expect(comparable(valid(), valid())).toBe(true));
  test("different machines, power, settings or fixture cannot compare", () => {
    for (const edit of [(r: Run) => r.provenance.machineID = "other", (r: Run) => r.provenance.osBuild = "other", (r: Run) => r.provenance.fixtureHash = "other", (r: Run) => r.environment.power = "battery", (r: Run) => r.options.cycles = 30]) { const b = valid(); edit(b); expect(comparable(valid(), b)).toBe(false); }
  });
  test("nearest rank percentiles preserve a tail outlier", () => { expect(percentile([...Array(18).fill(1), 100, 200], .95)).toBe(100); expect(percentile([], .95)).toBeNull(); });
});

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sealEvidence, verifyEvidence } from "../Scripts/bench/suite/evidence";

test("saved evidence detects a missing or modified raw record", async () => {
  const directory = mkdtempSync(join(tmpdir(), "dropy-evidence-"));
  try {
    await Bun.write(join(directory, "result.json"), "{}");
    await Bun.write(join(directory, "raw.json"), "[1,2,3]");
    await sealEvidence(directory);
    await verifyEvidence(directory);
    await Bun.write(join(directory, "raw.json"), "[1,2]");
    await expect(verifyEvidence(directory)).rejects.toThrow("Evidence missing or changed");
    rmSync(join(directory, "raw.json"));
    await expect(verifyEvidence(directory)).rejects.toThrow();
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test("report CLI exits nonzero for incomplete evidence and failed metrics", async () => {
  const directory = mkdtempSync(join(tmpdir(), "dropy-report-test-"));
  try {
    const file = join(directory, "result.json");
    const run = valid();
    await Bun.write(file, JSON.stringify(run));
    await Bun.write(join(directory, "raw.json"), "[]");
    await sealEvidence(directory);
    const command = () => Bun.spawn([process.execPath, join(import.meta.dir, "../Scripts/bench/suite.ts"), "check", file], { stdout: "ignore", stderr: "ignore" }).exited;
    expect(await command()).toBe(0);
    run.outcomes.native!.metrics.warmOpenMs = [];
    await Bun.write(file, JSON.stringify(run));
    await sealEvidence(directory);
    expect(await command()).toBe(1);
    rmSync(join(directory, "raw.json"));
    expect(await command()).toBe(2);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
