import { createHash } from "node:crypto";
import { readdirSync, readFileSync, lstatSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import type { Run } from "./model";

const digest = (path: string) => createHash("sha256").update(readFileSync(path)).digest("hex");
export async function sealEvidence(directory: string) {
  const files: { path: string; sha256: string }[] = [];
  function walk(dir: string) {
    for (const name of readdirSync(dir).sort()) {
      const path = join(dir, name), stat = lstatSync(path);
      if (stat.isSymbolicLink()) throw new Error("Evidence cannot contain symlinks");
      if (stat.isDirectory()) walk(path);
      else if (!["manifest.json", "report.md"].includes(name)) files.push({ path: relative(directory, path), sha256: digest(path) });
    }
  }
  walk(directory);
  await Bun.write(join(directory, "manifest.json"), JSON.stringify({ version: 1, files }, null, 2) + "\n");
}
export async function verifyEvidence(directory: string): Promise<void> {
  const manifest = await Bun.file(join(directory, "manifest.json")).json();
  if (manifest.version !== 1 || !Array.isArray(manifest.files) || !manifest.files.some((f: any) => f.path === "result.json")) throw new Error("Invalid evidence manifest");
  for (const file of manifest.files) {
    if (typeof file.path !== "string" || resolve(directory, file.path) !== join(resolve(directory), file.path) || file.path.startsWith("/") || file.path.split("/").includes("..")) throw new Error("Invalid evidence path");
    const path = join(directory, file.path);
    if (!lstatSync(path).isFile() || digest(path) !== file.sha256) throw new Error(`Evidence missing or changed: ${file.path}`);
  }
}

export function verifyReferencedEvidence(directory: string, run: Run) {
  for (const outcome of Object.values(run.outcomes)) {
    if (outcome?.status !== "passed") continue;
    for (const file of outcome.evidence) {
      if (file.startsWith("/") || file.split("/").includes("..")) throw new Error(`Nonportable evidence path: ${file}`);
      const path = join(directory, file), stat = lstatSync(path);
      if (stat.isSymbolicLink() || !(stat.isFile() || stat.isDirectory())) throw new Error(`Invalid evidence: ${file}`);
      if (stat.isDirectory() && readdirSync(path).length === 0) throw new Error(`Empty evidence directory: ${file}`);
    }
  }
}
