import { summarize } from "../stats";

export const schemaVersion = 2;
export const scenarios = ["control", "idle", "native", "pinned", "preview", "live", "staged-idle", "native-active", "preview-active", "live-active", "input-native", "input-live", "rapid", "recovery"] as const;
export type Scenario = typeof scenarios[number];
export type Profile = "smoke" | "standard" | "stress" | "soak";
export const profiles: Record<Profile, { scenarios: Scenario[]; cycles: number; seconds: number; keys: number }> = {
  smoke: { scenarios: ["control", "idle", "native", "preview"], cycles: 5, seconds: 5, keys: 30 },
  standard: { scenarios: [...scenarios], cycles: 30, seconds: 30, keys: 120 },
  stress: { scenarios: ["control", "input-native", "input-live", "rapid", "recovery"], cycles: 100, seconds: 30, keys: 300 },
  soak: { scenarios: ["native", "pinned", "live", "staged-idle", "native-active", "live-active"], cycles: 300, seconds: 600, keys: 120 },
};
export interface Options { profile: Profile; scenarios: Scenario[]; cycles: number; seconds: number; keys: number; build: boolean }
export function parseOptions(args: string[]): Options {
  const values = new Map<string, string>();
  let build = true;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--") continue;
    if (args[i] === "--no-build") { build = false; continue; }
    if (!["--profile", "--only", "--cycles", "--seconds", "--keys"].includes(args[i])) throw new Error(`Unknown option ${args[i]}`);
    const key = args[i], value = args[++i];
    if (!value || value.startsWith("--") || values.has(key)) throw new Error(`Missing or repeated ${key}`);
    values.set(key, value);
  }
  const profile = (values.get("--profile") ?? "smoke") as Profile;
  if (!Object.hasOwn(profiles, profile)) throw new Error(`Unknown profile ${profile}`);
  const defaults = profiles[profile];
  const selected = (values.get("--only")?.split(",") ?? defaults.scenarios) as Scenario[];
  if (!selected.length || new Set(selected).size !== selected.length || selected.some(s => !scenarios.includes(s))) throw new Error("Unknown or duplicate scenario");
  function number(name: string, fallback: number, min: number, max: number) {
    const n = Number(values.get(name) ?? fallback);
    if (!Number.isInteger(n) || n < min || n > max) throw new Error(`${name} must be an integer from ${min} to ${max}`);
    return n;
  }
  return { profile, scenarios: selected, cycles: number("--cycles", defaults.cycles, 3, 1000),
    seconds: number("--seconds", defaults.seconds, 3, 3600), keys: number("--keys", defaults.keys, 10, 2000), build };
}
export interface Check { name: string; passed: boolean; detail: string }
export interface Trial { iteration: number; warmup: boolean; mode: string; windowID: number; readyMs: number; closeObservedMs: number; firstFrameMs?: number; layoutChanges: number }
export interface Outcome {
  status: "passed" | "failed" | "blocked" | "not-run";
  reason?: string;
  trials: Trial[];
  metrics: Record<string, number[]>;
  checks: Check[];
  evidence: string[];
}
export interface Run {
  schemaVersion: 2; id: string; date: string; options: Options;
  provenance: Record<string, unknown>;
  environment: Record<string, any>;
  outcomes: Partial<Record<Scenario, Outcome>>;
  cleanup: Check[];
}
export const isLive = (s: Scenario) => s === "live" || s === "live-active" || s === "input-live";
export const isPinned = (s: Scenario) => isLive(s) || s === "pinned" || s === "staged-idle" || s === "recovery";
export const isPreview = (s: Scenario) => s === "preview" || s === "preview-active";
export const isCycles = (s: Scenario) => ["native", "pinned", "preview", "live"].includes(s);
export const expectedMode = (s: Scenario) => isLive(s) ? "live" : isPreview(s) ? "viewing" : "docked";

export function sameWindow(before: any, after: any): boolean {
  return !!before && !!after && before.windowID === after.windowID && before.minimized === after.minimized
    && Array.isArray(before.frame) && before.frame.length === 4 && Array.isArray(after.frame) && after.frame.length === 4
    && before.frame.every((v: number, i: number) => Number.isFinite(v) && Number.isFinite(after.frame[i]) && Math.abs(v - after.frame[i]) <= 2)
    && Array.isArray(before.spaces) && before.spaces.length > 0 && Array.isArray(after.spaces)
    && JSON.stringify([...before.spaces].sort()) === JSON.stringify([...after.spaces].sort());
}
export interface InputEvent { sequence: number; kind: string; keyCode: number; repeat: boolean; shift: boolean; latencyMs?: number }
export function validateInput(sent: InputEvent[], received: InputEvent[], decoy: InputEvent[]): Check[] {
  const shape = (e: InputEvent) => [e.sequence, e.kind, e.keyCode, e.repeat, e.shift];
  return [
    { name: "exact input sequence", passed: sent.length > 0 && JSON.stringify(sent.map(shape)) === JSON.stringify(received.map(shape)), detail: `${received.length}/${sent.length} target events, order and flags checked` },
    { name: "decoy untouched", passed: decoy.length === 0, detail: `${decoy.length} decoy events` },
    { name: "valid dispatch latency", passed: received.length > 0 && received.every(e => Number.isFinite(e.latencyMs) && e.latencyMs! >= 0), detail: "shared monotonic clock; event delivery, not pixel presentation" },
  ];
}
export interface Budget { metric: string; stat: "p50" | "p95" | "max" | "mean"; max: number; minimumSamples: number }
export const budgets: Partial<Record<Scenario, Budget[]>> = {
  native: [{ metric: "warmOpenMs", stat: "p95", max: 300, minimumSamples: 20 }, { metric: "coldOpenMs", stat: "max", max: 600, minimumSamples: 1 }, { metric: "dropy.cpuPercent", stat: "mean", max: 1, minimumSamples: 20 }],
  pinned: [{ metric: "warmOpenMs", stat: "p95", max: 300, minimumSamples: 20 }, { metric: "coldOpenMs", stat: "max", max: 600, minimumSamples: 1 }],
  preview: [{ metric: "warmOpenMs", stat: "p95", max: 600, minimumSamples: 20 }, { metric: "firstFrameMs", stat: "p95", max: 1000, minimumSamples: 20 }],
  live: [{ metric: "warmOpenMs", stat: "p95", max: 300, minimumSamples: 20 }, { metric: "coldOpenMs", stat: "max", max: 600, minimumSamples: 1 }, { metric: "dropy.cpuPercent", stat: "mean", max: 2, minimumSamples: 20 }],
  "staged-idle": [{ metric: "dropy.cpuPercent", stat: "mean", max: 1, minimumSamples: 20 }, { metric: "dropy.wakeupsPerSecond", stat: "mean", max: 1, minimumSamples: 20 }],
  "live-active": [{ metric: "dropy.cpuPercent", stat: "mean", max: 12, minimumSamples: 20 }],
  idle: [{ metric: "dropy.cpuPercent", stat: "mean", max: 1, minimumSamples: 20 }, { metric: "dropy.memoryMB", stat: "max", max: 120, minimumSamples: 20 }],
};
export function evaluate(run: Run): { passed: boolean; checks: Check[]; qualification: string } {
  const checks: Check[] = [];
  if (run.schemaVersion !== 2) return { passed: false, checks: [{ name: "schema", passed: false, detail: "Requires v2 evidence; legacy results cannot qualify" }], qualification: "invalid" };
  for (const scenario of run.options.scenarios) {
    const outcome = run.outcomes[scenario];
    checks.push({ name: scenario, passed: outcome?.status === "passed", detail: outcome?.reason ?? outcome?.status ?? "missing scenario" });
    if (!outcome) continue;
    checks.push(...outcome.checks.map(c => ({ ...c, name: `${scenario}: ${c.name}` })));
    checks.push({ name: `${scenario}: evidence`, passed: outcome.evidence.length > 0 && outcome.checks.length > 0, detail: "raw evidence and correctness checks required" });
    if (isCycles(scenario)) {
      const measured = outcome.trials.filter(t => !t.warmup);
      checks.push({ name: `${scenario}: complete cycles`, passed: measured.length === run.options.cycles && measured.every(t => t.mode === expectedMode(scenario) && t.windowID > 0 && Number.isFinite(t.readyMs) && t.readyMs >= 0), detail: `${measured.length}/${run.options.cycles}` });
    }
    const required = scenario === "control" ? ["fixture.cpuPercent", "fixture.memoryMB"] : ["dropy.cpuPercent", "dropy.memoryMB"];
    for (const metric of required) {
      const values = outcome.metrics[metric];
      checks.push({ name: `${scenario}: ${metric}`, passed: !!values && values.length >= run.options.seconds && values.every(v => Number.isFinite(v) && v >= 0), detail: `${values?.length ?? 0}/${run.options.seconds} samples` });
    }
    for (const budget of budgets[scenario] ?? []) {
      const values = outcome.metrics[budget.metric] ?? [];
      const value = summarize(values)[budget.stat];
      // Smoke is diagnostic: still enforce limits, but cannot qualify a p95 with five samples.
      const enough = values.length >= (run.options.profile === "smoke" ? 1 : budget.minimumSamples);
      checks.push({ name: `${scenario}: ${budget.metric}.${budget.stat}`, passed: enough && value !== null && Number.isFinite(value) && value <= budget.max,
        detail: `${value ?? "missing"} <= ${budget.max}; n=${values.length}, required=${run.options.profile === "smoke" ? 1 : budget.minimumSamples}` });
    }
  }
  checks.push({ name: "cleanup recorded", passed: run.cleanup.length > 0, detail: "cleanup failures invalidate the run" }, ...run.cleanup);
  const passed = checks.every(c => c.passed);
  return { passed, checks, qualification: run.options.profile === "smoke" ? "smoke only — no release qualification" : "measured scenarios only — hardware and user validation still required" };
}
export function comparable(a: Run, b: Run): boolean {
  // Same model is not same machine. Machine ID is a locally hashed hardware UUID.
  const workload = ({ build, ...rest }: Options) => rest;
  return typeof a.provenance.machineID === "string" && a.provenance.machineID.length > 0
    && a.schemaVersion === b.schemaVersion && a.provenance.machineID === b.provenance.machineID
    && a.provenance.osBuild === b.provenance.osBuild && a.provenance.arch === b.provenance.arch
    && a.provenance.buildMode === b.provenance.buildMode && a.provenance.fixtureHash === b.provenance.fixtureHash
    && JSON.stringify(a.environment.displays) === JSON.stringify(b.environment.displays)
    && a.environment.power === b.environment.power && a.environment.lowPower === b.environment.lowPower
    && JSON.stringify(workload(a.options)) === JSON.stringify(workload(b.options));
}
