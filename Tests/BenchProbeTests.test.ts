import { expect, test } from "bun:test";
import { startProbe } from "../Scripts/bench/probe-process";
import { copyFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

test("startup failure returns its diagnostic without hanging", async () => {
  const probe = startProbe(["/bin/sh", "-c", "echo capture-denied >&2; exit 1"], 2000);
  const result = await probe.result;
  expect(result.exitCode).toBe(1);
  expect(result.stderr).toContain("capture-denied");
  expect(result.timedOut).toBe(false);
});

test("a hung probe is killed and its pipes finish", async () => {
  const probe = startProbe(["/bin/sleep", "60"], 50);
  const result = await probe.result;
  expect(result.timedOut).toBe(true);
  expect(result.exitCode).not.toBe(0);
});

test("scenario cleanup can stop a still-running probe", async () => {
  const probe = startProbe(["/bin/sleep", "60"], 2000);
  probe.stop();
  const result = await probe.result;
  expect(result.exitCode).not.toBe(0);
  expect(result.timedOut).toBe(false);
});

test("successful output remains available", async () => {
  const probe = startProbe(["/bin/sh", "-c", "echo 'probe: frames=20 gapFrames=0'"], 2000);
  const result = await probe.result;
  expect(result.exitCode).toBe(0);
  expect(result.stdout).toContain("gapFrames=0");
  expect(result.timedOut).toBe(false);
});

test("the Swift probe exits nonzero when capture startup throws", async () => {
  const work = mkdtempSync(join(tmpdir(), "dropy-probe-check-"));
  try {
    const source = join(work, "main.swift"), binary = join(work, "probe");
    copyFileSync(join(import.meta.dir, "../Scripts/bench/topedge.swift"), source);
    const compile = startProbe(["swiftc", source, join(import.meta.dir, "Fixtures/TopedgeStartupFailure.swift"), "-o", binary], 10000);
    const compiled = await compile.result;
    expect(compiled.stderr).not.toContain("error:");
    expect(compiled.exitCode).toBe(0);
    const result = await startProbe([binary, "0.1"], 2000).result;
    expect(result.exitCode).toBe(1);
    expect(result.timedOut).toBe(false);
    expect(result.stderr).toContain("probe-startup-fixture");
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}, 15000);
