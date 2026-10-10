#!/usr/bin/env bun
// Reads `WindowTool snapshot` JSON on stdin and exits 0 when the given window is on a
// desktop that is not showing (used by Scripts/device-checks.sh).
// Usage: WindowTool snapshot <pid> <window> | bun Scripts/bench/space-check.ts <window-id>
const wanted = Number(process.argv[2]);
const snapshot = JSON.parse(await Bun.stdin.text());
const window = (snapshot.serverWindows ?? []).find((w: { id: number }) => w.id === wanted) ?? {};
const active = new Set<number>(snapshot.activeSpaces ?? []);
const spaces: number[] = window.spaces ?? [];
process.exit(active.size > 0 && spaces.length > 0 && spaces.every((space) => !active.has(space)) ? 0 : 1);
