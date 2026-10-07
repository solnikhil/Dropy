#!/usr/bin/env bun
// Summarises `Dropy frame trace:` lines (DROPY_DEBUG_FRAME_TRACE=1) from a Dropy log.
//
// Frames are grouped as
//   response   the first traced frame displayed after an input mark (one per input),
//   follow-up  later frames carrying the same input mark,
//   no input   frames before any input.
// For each group, per-stage p50 / p95 / max in milliseconds, plus a per-input table.
// Usage: bun Scripts/bench/latency-summary.ts <dropy.log>
import { fmt, percentile } from "./stats";

const STAGES = ["capture", "compare", "forward", "main", "draw", "compose", "age"];
type Frame = Record<string, number> & { presented: boolean; drawLog: string };

const path = process.argv[2];
if (!path) {
  console.error("usage: bun Scripts/bench/latency-summary.ts <dropy.log>");
  process.exit(2);
}
const text = await Bun.file(path).text();

const frames: Frame[] = [];
for (const line of text.split("\n")) {
  const at = line.indexOf("Dropy frame trace:");
  if (at < 0) continue;
  const body = line.slice(at + "Dropy frame trace:".length);
  const frame = { presented: true, drawLog: "" } as Frame;
  for (const [, key, value] of body.matchAll(/(\w+)=([-\w.]+)/g)) {
    if (/^-?[0-9.]+$/.test(value)) frame[key] = Number(value);
    if (key === "outcome") frame.presented = value !== "notPresented";
  }
  frame.drawLog = body.match(/drawLog=(\S+)/)?.[1] ?? "";
  frames.push(frame);
}

function table(title: string, group: Frame[]): string[] {
  const misses = group.reduce((sum, f) => sum + (f.misses ?? 0), 0);
  const out = [
    `### ${title} (${group.length} frames, ${group.filter((f) => !f.presented).length} not presented, ${misses} drawable misses)`,
    "",
    "| Stage | p50 | p95 | max |",
    "|---|---|---|---|",
  ];
  for (const stage of [...STAGES, "inputToDisplay", "inputToPresent"]) {
    const values = group.filter((f) => stage in f).map((f) => f[stage]);
    if (values.length) {
      out.push(`| ${stage} | ${fmt(percentile(values, 0.5))} | ${fmt(percentile(values, 0.95))} | ${fmt(Math.max(...values))} |`);
    }
  }
  return out;
}

const inputs = [...new Set(frames.filter((f) => "input" in f).map((f) => f.input))].sort((a, b) => a - b);
const none = frames.filter((f) => !("input" in f));
const response: Frame[] = [];
const follow: Frame[] = [];
for (const mark of inputs) {
  const carrying = frames.filter((f) => f.input === mark && (f.inputToDisplay ?? -1) >= 0);
  if (carrying.length) {
    response.push(carrying[0]);
    follow.push(...carrying.slice(1));
  }
}
const lines = [`Distinct input marks traced: ${inputs.length}; inputs with a response frame: ${response.length}.`, ""];
lines.push(...table("Response frames (idle input to visible update)", response), "");
lines.push(...table("Follow-up frames after an input", follow), "");
lines.push(...table("Frames with no input (quiet period)", none), "");
lines.push("### Per input", "",
  "| # | inputToDisplay | inputToPresent | capture | main | draw | compose | draws | misses | draw log (ms after delivery) |",
  "|---|---|---|---|---|---|---|---|---|---|");
response.forEach((f, index) => {
  lines.push(`| ${index + 1} | ${fmt(f.inputToDisplay)} | ${fmt(f.inputToPresent)} | ${fmt(f.capture)} | ${fmt(f.main)} | ` +
    `${fmt(f.draw)} | ${fmt(f.compose)} | ${f.draws ?? 0} | ${f.misses ?? 0} | ${f.drawLog || "—"} |`);
});
console.log(lines.join("\n"));
