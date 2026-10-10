/** Drain output from launch and bound the entire probe lifetime, including startup.
 * Keeping the result non-throwing lets benchmark cleanup run on every exit path. */
export function startProbe(command: string[], timeoutMs: number) {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error("Invalid probe timeout");
  const process = Bun.spawn(command, { stdout: "pipe", stderr: "pipe" });
  let timedOut = false;
  const stop = () => { if (process.exitCode === null) process.kill("SIGKILL"); };
  const timer = setTimeout(() => { timedOut = true; stop(); }, timeoutMs);
  const result = Promise.all([
    process.exited,
    new Response(process.stdout).text(),
    new Response(process.stderr).text(),
  ]).then(([exitCode, stdout, stderr]) => ({ exitCode, stdout, stderr, timedOut }))
    .finally(() => clearTimeout(timer));
  return { result, stop };
}
