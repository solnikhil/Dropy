# Dropy performance and reliability benchmarks

The current suite tests the real-window Native path, pinned windows on the Stage, Preview, and Live over a disposable full-screen app. It uses generated AppKit windows, including a decoy from the same process. It never opens TextEdit, Preview, personal documents, or an installed third-party app.

A successful synthetic run qualifies only the measured scenarios on the recorded machine. It does **not** establish third-party compatibility, input-to-photon latency, or whether people want the product. See [the real-use validation protocol](USER-VALIDATION.md) for those separate questions.

## Commands

```sh
bun run bench:plan                       # inspect smoke workload, no UI
bun run bench:plan -- --profile standard
bun run bench:build                      # optimized -O app + fixtures; no UI
bun run bench:preflight                  # read permissions/session/power; no prompts
bun run bench:test                       # benchmark validity and failure-path tests

# Quit Dropy, leave the Mac awake/unlocked and idle for at least five seconds.
# The suite refuses a running Dropy, pending recovery, or a permission prompt.
caffeinate -d bun run bench -- --no-build
caffeinate -d bun run bench -- --profile standard --no-build
caffeinate -d bun run bench -- --profile stress --no-build
caffeinate -d bun run bench -- --profile soak --no-build

# Narrow diagnostic runs never stand in for omitted scenarios.
caffeinate -d bun run bench -- --only native --cycles 30 --seconds 30 --no-build
bun run bench:check                      # latest result and evidence integrity
bun run bench:check /absolute/path/result.json
bun run bench:compare /absolute/path/first/result.json /absolute/path/second/result.json
bun run bench:list
```

Without `--no-build`, a live run builds first. Building separately avoids having to leave the Mac idle throughout compilation. The optimized app lives in `.build/bench-suite/Dropy.app`, leaving `.build/local` and `/Applications` alone. Its signing identity follows the existing local build policy; it is not a notarized distribution build. Permissions must already be available to this signed build and the tool. Preflight does not request them or interact with prompts.

`--cycles` accepts 3–1000, `--seconds` 3–3600, `--keys` 10–2000. Unknown, duplicate and missing options are rejected. `--only` accepts comma-separated scenario names. Settings are fixed to Balanced, Compact, Fit, notch position, manual dismissal, and Control-Option-D; the full preferences backup is restored by the desktop-session owner after the processes exit. “Protect Video” is disabled for this test because Stage/Live must be measured; do not play protected video during a live run.

## Workloads

| Scenario | Question and required evidence |
|---|---|
| `control` | How does the disposable app behave without Dropy? Typing/repeat/chord delivery plus static CPU, physical footprint, wakeups and system GPU observations |
| `idle` | What does Dropy cost while closed with no staged window? |
| `native` | Repeated ordinary-window opening and restoration: exact identity, mode, internal ready latency, externally observed close, geometry and Space |
| `pinned` | Repeated openings from and returns to the Stage; final quit restores the source |
| `preview` | Opening and first compositor-presented preview frame; recording must remain active |
| `live` | Open the target over a separate disposable full-screen fixture; Preview/Native fallback is a failure |
| `staged-idle` | Resource use while a pinned target waits on the hidden Stage |
| `native-active` | Native steady-state overhead while the fixture changes its background at a requested 60 Hz |
| `preview-active` | Preview presentation rate, frame-age/callback samples, resource use under changing content |
| `live-active` | Same capture/resource measurements for Live, including WindowServer and system GPU samples |
| `input-native`, `input-live` | Exact event order/count/key codes/repeat/modifier flags in the target, zero events in the decoy, dispatch latency and achieved injection rate |
| `rapid` | Repeated open/close interruption with requested delays of 0/16/50/100 ms, eventual restoration, then the real global shortcut opening and closing through HID/Carbon |
| `recovery` | Stage a disposable target, verify its journal, SIGKILL only the benchmark-owned Dropy, relaunch, and verify original geometry **and Space** |

Profiles:

- **Smoke:** control, idle, Native, Preview; 5 measured openings, 5 resource samples and 30 input groups at 10/s. Diagnostic only; never a release qualification.
- **Standard:** every scenario; 30 measured openings, 30 seconds per resource interval and 120 input groups at each rate.
- **Stress:** control, Native/Live input, rapid interruption and crash recovery; 100 cycles and 300 input groups.
- **Soak:** Native, pinned, Live, staged-idle, Native-active and Live-active; 300 cycles and ten minutes per resource interval. Expect a long run; use AC power for comparable thermal conditions.

Every cycle scenario records its first process-cold opening separately. The first two openings are excluded from the warm distribution. “Cold” does not imply cold OS/filesystem/GPU caches. The Stage may start during app initialization: `launchObservedMs` records LaunchServices-to-control-ready time (including harness overhead), and `stageReadyAtControlStartup` records whether it was already ready. First-opening latency includes only work on the opening path; it does not silently claim to include all process or Stage startup time.

Input rates are 10, 30, 60 and 120 **groups/second**, except smoke's 10/s. Typing sends one down/up pair per group; repeat holds a key, sends repeated downs, then releases; chord holds three keys with Shift and releases in reverse order. The achieved rate must reach 85% of requested rate or the workload fails as under-delivered. These high rates are overload probes, not claims about human typing speed. The tool verifies the exact disposable target's frontmost/focused window before each group and stops when focus changes or a system prompt appears. It releases keys it has posted. No actual hardware clock is changed.

Rapid opening uses the app's ordinary open/close methods via an opt-in local control channel. It tests cancellation and ownership; it is not a measurement of hardware shortcut throughput. Command-process/IPC overhead is recorded in actual cycle duration. The separate acknowledged HID shortcut check tests shortcut integration.

## Metrics and gates

Raw resource samples are one second apart. CPU uses the difference in process CPU time divided by a monotonic elapsed interval; 100% means one logical core. The sampler's CPU-clock self-check must pass at build time. Memory uses physical footprint when available and explicitly labels an RSS fallback. WindowServer readings fall back to `ps`; system GPU is not attributed solely to Dropy. A missing GPU counter remains unavailable, never zero.

Ready latency comes from the app's existing readiness transition using its monotonic clock. Preview first-frame latency is compositor presentation, not merely a successful startCapture call. Capture evidence includes raw frame ages, callback-to-presentation and capture-to-callback samples plus presentation counts and clock offset. Changing-content capture must continue presenting at a conservative minimum of 20 fps; meeting that floor is a liveness check, not proof of smooth 60/120 Hz animation. Capture clock offsets over 1 ms, negative samples, blank/suspended capture or a mode change fail the scenario. Memory growth is the last-quarter mean minus the first-quarter mean of the interval; it is a drift observation, not proof of a leak. Long capture traces have the existing 36,000-sample cap, recorded with the evidence; no tail claims should be made beyond retained samples.

Input dispatch latency uses the injected event's explicit monotonic timestamp and the fixture's receipt time. It measures event delivery to a custom responder. It does not prove text editing, IME composition, undo, shortcuts, menus, or visible response time in a real application. Final received events are checked exactly, including up events, repeats and flags. Wrong-window delivery is always a failure.

Close time is externally observed through commands and window snapshots, so it includes polling/IPC overhead and must not be compared directly with the old internal `closeHomeMs` metric.

The executable policy is in [`Scripts/bench/suite/model.ts`](../Scripts/bench/suite/model.ts). Product latency/resource targets come from the [interaction plan](design/2026-10-07-interaction-engine-plan.md):

| Gate | Target |
|---|---|
| Native/pinned/Live warm ready p95 | ≤300 ms; at least 20 warm samples outside smoke |
| Native/pinned/Live process-cold ready | ≤600 ms; first opening recorded separately |
| Preview warm ready / first-presented-frame p95 | ≤600 / ≤1000 ms; inherited preview ceilings |
| Closed CPU / max footprint | ≤1% / ≤120 MiB; inherited idle ceilings |
| Native steady CPU | ≤1% (operational tolerance for the plan's approximately-zero target) |
| Staged-idle CPU / idle wakeups | ≤1% / ≤1 per second |
| Live static / active CPU | ≤2% / ≤12% |
| Correctness, restoration and cleanup | Zero failures |

Do not relax gates to make a run green. An early prototype's historical 800–1000 ms ceilings are not the product target. Threshold changes need a documented reason and new baseline. At least three independent standard runs per supported hardware configuration are needed to assess variance; a single passing run is not stability evidence. p95 from smoke is descriptive only. GPU deltas, cursor lag, true input-to-visible latency, long-term memory leak qualification and 120 Hz frame pacing still need additional controlled experiments; the suite does not claim those gates passed.

## Evidence, comparison and failure handling

Each run writes `.build/benchmark-results/<timestamp>-<id>/result.json`, a readable `report.md`, app logs, per-command replies, resource rows, full generated input sequences and before/after restoration snapshots. A SHA-256 manifest covers the result and raw files; `check` and `compare` refuse missing or changed evidence. Copy the entire run directory when sharing, not only its report.

Attribution records full Git commit, dirty status, source hash, exact optimized binary hash, fixture hash, Swift/Bun versions, OS build, architecture and a locally hashed machine identifier. Sources changing during a build or measurement invalidate attribution. Comparison requires the same machine, OS build, display geometry/scale/refresh rate, power/low-power mode, fixture, optimized configuration and workload. A latency regression is >25% **and** >40 ms on warm p95. Failed/incomplete results are not eligible baselines. Compare resource and input metrics as observations; no statistical confidence is implied.

Missing mandatory samples, unexpected modes, unrun scenarios, failed event validation, thermal pressure, display/power changes and failed cleanup all prevent a pass. Raw failures remain saved. The desktop-session lock prevents simultaneous device suites, retains a durable preferences backup and checks battery/idle/prompt conditions. A normal interrupt finishes in-flight balanced input, then cleans up. SIGKILL cannot run cleanup; the next session restores preferences, and Dropy's journal remains available for window recovery. The suite refuses to start over pending recovery. It never kills an unrelated Dropy process.

The control channel exists only when `DROPY_DEBUG_BENCHMARK` names a private per-run directory. It has no polling timer in normal app launches. Commands use a per-process notification name and UUID reply filenames. During resource intervals there is no command polling. Reads before and after the interval preserve capture evidence without periodic benchmark wakeups in the app.

## Current evidence status

Harness tests, build results and any live-run outcome must be reported separately. Do not promote archived figures to the current Native/Stage/Live architecture. The older capture experiments and 2026-10-08 runner are retained in [the historical method](benchmarks/legacy-method.md); their results have a different schema and cannot qualify this suite.
