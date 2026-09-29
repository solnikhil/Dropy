#!/usr/bin/env python3
"""Summarises `Dropy frame trace:` lines (DROPY_DEBUG_FRAME_TRACE=1) from a Dropy log.

Frames are grouped as
  response  the first traced frame displayed after an input Dropy sent (one per click),
  follow-up later frames carrying the same input mark,
  no input  frames before any input.
For each group, per-stage p50 / p95 / max in milliseconds, plus a per-click table.
Percentiles use nearest rank, like CaptureMetrics.
"""
import math
import re
import sys

STAGES = ["capture", "compare", "forward", "main", "draw", "compose", "age"]


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(p * len(ordered)) - 1))]


def fmt(value):
    return "—" if value is None else f"{value:.1f}"


def parse(path):
    frames = []
    for line in open(path, errors="replace"):
        if "Dropy frame trace:" not in line:
            continue
        body = line.split("Dropy frame trace:", 1)[1]
        fields = dict(re.findall(r"(\w+)=([-\w.]+)", body))
        frame = {k: float(v) for k, v in fields.items() if re.fullmatch(r"-?[0-9.]+", v)}
        frame["presented"] = fields.get("outcome") != "notPresented"
        frames.append(frame)
    return frames


def table(title, frames):
    out = [f"### {title} ({len(frames)} frames, "
           f"{sum(1 for f in frames if not f['presented'])} not presented, "
           f"{int(sum(f.get('misses', 0) for f in frames))} drawable misses)", "",
           "| Stage | p50 | p95 | max |", "|---|---|---|---|"]
    for stage in STAGES + ["inputToDisplay", "inputToPresent"]:
        values = [f[stage] for f in frames if stage in f]
        if values:
            out.append(f"| {stage} | {fmt(percentile(values, .5))} | {fmt(percentile(values, .95))} | {fmt(max(values))} |")
    return out


def main():
    frames = parse(sys.argv[1])
    inputs = sorted({f["input"] for f in frames if "input" in f})
    sent = len(re.findall(r"Dropy input: kind=pointerClick \S+ route=", open(sys.argv[1], errors="replace").read()))
    none = [f for f in frames if "input" not in f]
    response, follow = [], []
    for mark in inputs:
        carrying = [f for f in frames if f.get("input") == mark and f.get("inputToDisplay", -1) >= 0]
        if carrying:
            response.append(carrying[0])
            follow.extend(carrying[1:])
    lines = [f"Clicks routed: {sent}; distinct input marks traced: {len(inputs)}; "
             f"clicks with a response frame: {len(response)}.", ""]
    lines += table("Response frames (idle input to visible update)", response) + [""]
    lines += table("Follow-up frames after an input", follow) + [""]
    lines += table("Frames with no input (quiet period)", none) + [""]
    lines += ["### Per click", "", "| # | inputToDisplay | inputToPresent | capture | main | draw | compose | draws | misses |",
              "|---|---|---|---|---|---|---|---|---|"]
    for index, f in enumerate(response, 1):
        lines.append(f"| {index} | {fmt(f.get('inputToDisplay'))} | {fmt(f.get('inputToPresent'))} | {fmt(f.get('capture'))} | "
                     f"{fmt(f.get('main'))} | {fmt(f.get('draw'))} | {fmt(f.get('compose'))} | {int(f.get('draws', 0))} | "
                     f"{int(f.get('misses', 0))} |")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
