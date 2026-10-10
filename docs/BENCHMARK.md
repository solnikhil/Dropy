# Capture benchmark

## Benchmarking a version (Bun, 2026-10-08)

Dropy's tooling runs on [Bun](https://bun.sh). From the repository root:

```sh
caffeinate -d bun run bench          # build, measure every scenario, save, check
bun run bench -- --animation ~/Library/Application\ Support/Dropy/Animations/mine.json   # with your own animation
bun run bench -- --cycles 8 --style rapid --no-build --only native,pinned
bun run bench:check                  # newest result against budgets and the previous run
bun run bench:compare                # the two newest results side by side
bun run bench:list                   # every saved result with its commit
```

Each run measures the current build on this Mac against a scratch TextEdit document (nothing of the person's is opened or moved), saves `docs/benchmarks/results/<date>-<commit>[-dirty].json`, and checks it:

| Scenario | What it measures |
|---|---|
| `native` | Full App, direct open, Native size: request → docked window (`openReadyMs`), size changes on the way (`layoutChanges`, must be 0), close → window back home (`closeHomeMs`), frames where the overlay was not flush with the top of the screen (`topGapFrames`, must be 0; `Scripts/bench/topedge.swift` streams the strip under the notch at 120 fps and needs Screen Recording for the terminal), CPU and memory |
| `pinned` | The same app pinned and kept ready: openings from the Stage, closes to it, Stage creation time |
| `preview` | Preview only: request → live preview, first frame on screen |
| `fullscreen` | Pinned, opened over a scratch image shown full screen in Preview (Live mode), with "When the pointer leaves" dismissal. Each opening also moves the pointer into the app, clicks it and moves back out; the overlay must stay open, the pointer must be handed to the Stage and come back |
| `idle` | Overlay closed: CPU and memory |

Budgets are in `docs/benchmarks/budgets.json`; a result also fails when an opening never became ready, or when a latency is more than 25 % and 40 ms slower than the previous result from the same Mac model and macOS. Runs refuse to start on a locked screen and are discarded if it locks or capture is suspended part way: a locked Mac measured on 2026-10-08 showed broken Accessibility and suspended capture, nothing like normal use. Dropy's preferences are exported first and restored after; TextEdit comes to the front while it runs.

The timings come from one log line per opening (`Dropy timing: ready mode=… ms=… layoutChanges=…`) and per close (`Dropy timing: closed home=…`).

**First baseline** (2026-10-08, `48a2dd2` plus the first-opening fix, M2 MacBook Air, macOS 27.0.1, Balanced, 4 openings per scenario; the run's file was not kept):

| Scenario | Open p50 / max | Layout changes | Close home p50 / p95 | Other |
|---|---|---|---|---|
| native | 666 / 755 ms | 0 | 65 / 70 ms | CPU mean 3.2 % |
| pinned | 668 / 687 ms | 0 | 98 / 118 ms | Stage ready in 422 ms |
| preview | 231 ms (first frame 249 / 266 ms) | 0 | — | — |
| idle | — | — | — | CPU 0.0 %, 61 MB |

Full screen (2026-10-08, `3e59cc4` plus the fix below, 3 openings): open 695 / 860 ms (the first opening after launch, which brings the window from its desktop through the Stage, took 2.2 s in an earlier run), layout changes 0, close 42 / 43 ms, pointer check 3 of 3. Before the fix, Live mode closed the moment the pointer went into the app: the hand-off moves the real pointer to the Stage, which the overlay's pointer-leave watcher read as leaving, and a click in the app there counted as a click outside. The same check on that build: 0 of 2.

Top edge (2026-10-08): every opening began with the system's "window appears" zoom, which scales a new window in from slightly smaller, so the overlay's top edge sat below the screen's and the menu bar showed above it: 12 such frames on the first opening (a 12 px gap closing over about 90 ms) and 1–2 on later ones. With the zoom turned off (`animationBehavior = .none`), 0 frames over 5 openings.

Before the fix, a Native-size opening grew to the preset's size first and morphed again once the window list arrived (`layoutChanges` 1), and the first opening after launch could wait for the Stage.

## The capture path (2026-09)

This page explains what Dropy measures, how to reproduce the numbers, and what the first baseline shows. It covers the view-only capture path in M1. Input response time needs the M3 input bridge and is not measured yet.

## What is measured

**In the app.** Each stream logs one `Dropy capture metrics:` line when it stops. The line holds counts and timings only: no pixels, window titles, app names or text.

| Field | Meaning | Clock |
|---|---|---|
| `start` | Start request → `SCStream.startCapture` returned | mach host time |
| `firstFrame` | Start request → first *complete* frame in Dropy's callback | mach host time |
| `output` | Stream pixel size and format | — |
| `status` | Frames by ScreenCaptureKit status (`complete`, `idle`, `blank`, `suspended`, …) | — |
| `mailboxDrops` | Complete frames replaced before the main thread took them (latest-frame policy) | — |
| `presented` / `notPresented` | Frames the compositor reported shown, or never shown (for example a replaced drawable) | — |
| `drawableMisses` | Drawable attempts not shown, including retries whose frame later succeeds | — |
| `captureToCallback` | `SCStreamFrameInfo.displayTime` → Dropy's callback | mach host time on both sides |
| `callbackToPresent` | Callback → `MTLDrawable.presentedTime` | mach time vs Core Animation media time |
| `frameAge` | `displayTime` → on-glass presentation, per shown frame | as above |
| `clockOffset` | Measured Core Animation minus mach offset | — |

Percentiles use nearest rank. They are printed only when the clocks agree: an offset of at most 1 ms and at least 99% of intervals between 0 and 1 s. Otherwise the field reads `unchecked-clock`.

`Dropy reveal:` logs the time from the overlay open request to the first captured frame on screen. `warm=yes` means the process has opened the overlay before.

**Around the app.** `Scripts/benchmark.sh` runs each workload twice, first without Dropy and then with Dropy previewing the workload window. A small sampler (`Scripts/bench/Sampler.swift`) reads once per second:

- Dropy CPU, memory footprint, idle wakeups and interrupt wakeups, from `proc_pid_rusage`.
- WindowServer CPU, from `ps`. Its footprint and wakeups need root: use `sudo powermetrics --samplers tasks,gpu_power` for those.
- System GPU utilization, from the `IOAccelerator` `PerformanceStatistics` "Device Utilization %". This is system-wide, so Dropy's share is the difference between the two phases.

Workloads:

| Name | Window | Content |
|---|---|---|
| `static` | TextEdit document | Unchanging text |
| `scroll` | Safari, `Scripts/bench/scroll.html` | Scrolls itself 4 px per frame |
| `animation` | Safari, `Scripts/bench/animation.html` | Full-window canvas motion at display rate. It stands in for video but exercises no media decoder |

Development-only drivers make runs repeatable without input automation:

- `DROPY_DEBUG_CYCLES=<n>[,<hold-ms>]`: repeated open → live preview → close cycles.
- `DROPY_DEBUG_ALTERNATE`: rapid A/B switching.
- `DROPY_DEBUG_QUIT_AFTER=<s>`: a clean exit, so every summary is logged.

## Reproduce

```sh
# Terminal with Screen Recording; TextEdit and Safari not running; Mac otherwise idle.
caffeinate -d ./Scripts/benchmark-phases.sh 30     # coordinated: none / closed / idle / active
caffeinate -d ./Scripts/benchmark.sh 20            # all workloads, 20 s per phase
./Scripts/benchmark.sh 20 animation                # one workload
env DROPY_DEBUG_CYCLES=20,800 DROPY_DEBUG_QUIT_AFTER=60 \
  .build/local/Dropy.app/Contents/MacOS/Dropy --show   # cycles, with direct-open set to a running app
```

Reports are written to `.build/local/benchmark-<timestamp>.md`.

## Baseline, 2026-09-26

Setup: M2 MacBook Air (`Mac14,2`), macOS 27.0 (26A428), built-in 2560×1664 Retina display, overlay at the medium size (1176×705 stream), fit mode, Dropy `18ad4dd`. Raw reports: [run 1](benchmarks/2026-09-26-run1-aerial-wallpaper.md) (Aerial wallpaper) and [run 2](benchmarks/2026-09-26-run2-still-wallpaper.md) (still wallpaper).

**The system was not idle.** WindowServer used about 44% CPU with or without Dropy. Cloudflare WARP (about 31%), `mediaanalysisd` (about 18%) and browser helper processes playing media were running. Swapping the Aerial wallpaper for a still one changed nothing measurable. Treat these results as a loaded-system baseline.

**Correction (2026-09-29): the Dropy CPU figures in these two reports are valid; the later "fix" was wrong.** They were computed by converting `proc_pid_rusage` times from mach ticks with this Mac's 125/3 timebase. That conversion was then removed on the belief that the fields are nanoseconds. A direct check disproves it: a 1 s busy loop read 23.9 M units against 0.995 s of `CLOCK_PROCESS_CPUTIME_ID`, i.e. ticks. Every Sampler CPU figure between that change and 2026-09-29 was about 42× too low. The Sampler converts ticks again and runs `Sampler self-check` (rusage against the process CPU clock, must agree within 5%) before every benchmark. WindowServer CPU came from `ps` and was never affected.

| Workload | Run | GPU util without → with Dropy | Complete frames/s | Not presented | Frame age p50 / p95 / p99 (ms) | Cold reveal |
|---|---|---|---|---|---|---|
| static | 1 | 11 → 44% | 57.6 | 1 of 1427 | 26.9 / 36.0 / 41.0 | 468 ms |
| static | 2 | 12 → 45% | 57.5 | 2 of 1429 | 42.1 / 51.9 / 52.7 | 440 ms |
| scroll | 1 | 18 → 47% | 57.7 | 2 of 1434 | 28.4 / 35.4 / 37.3 | 505 ms |
| scroll | 2 | 18 → 48% | 57.7 | 2 of 1423 | 40.2 / 51.9 / 53.0 | 559 ms |
| animation | 1 | 33 → 55% | 56.0 | **697 of 1361** | 48.0 / 59.1 / 65.5 | 775 ms |
| animation | 2 | 32 → 58% | 57.8 | 4 of 1426 | 29.8 / 36.4 / 41.1 | 673 ms |

Held steady in every run:

- `captureToCallback` p50 0.7–0.8 ms, p99 2.6–7.5 ms.
- WindowServer CPU within about ±2 points of its baseline.
- Dropy footprint 33–37 MB.
- Dropy idle wakeups 0/s; interrupt wakeups 10–24/s.
- Clock offset 0.000 ms, so every percentile passed the clock check.

Open/close cycles (static TextEdit, 20 cycles, 800 ms hold): all 20 reached a live preview; cold reveal 426 ms; warm reveal p50 237 ms / p95 261 ms; never more than one stream running; zero streams after the last close; 20 metrics summaries, all with `stop=closed`.

## Findings

1. **Most of the frame age happens after the callback.** Delivery from ScreenCaptureKit to Dropy takes under 1 ms at p50. The rest, 26–48 ms at p50, is the main-thread handoff plus an `MTKView` redrawn through `setNeedsDisplay`, which usually lands two display refreshes later. That path is the first thing to optimize.
2. **Presentation can collapse under load.** In one animation run, half the frames sent to the renderer were never shown and frame age rose by about 20 ms. The next run was clean. This needs repeat runs and a GPU trace.
3. **"Static" windows are not idle.** A TextEdit window with no visible change still produced about 57 complete frames per second, so Dropy did full-rate work for unchanging content. It's unclear whether that comes from this macOS version or from the background compositing load. Rerun on an idle system and compare the `idle` frame count.
4. **The GPU cost is significant.** Dropy added 22–36 points of system GPU utilization. Some of it is the 60 Hz redraw of the preview itself, so fixing findings 1 and 3 should also reduce it.
5. **Start dominates reveal.** About 250–440 ms of a cold reveal is the stream start. Warm opens are about 240 ms.

## Follow-up measurements, 2026-09-26/27

Same Mac and display, same loaded background. These were controlled A/B checks rather than full benchmark runs.

- **Title bars make static windows look busy.** A borderless opaque test window captured `complete=2`, then only `idle` frames. The same window with a standard title bar produced a complete, fully dirty frame on every refresh, even over a static backdrop. For TextEdit, 291 of 294 of those frames were byte-identical to the previous one, so the dirty rects give Dropy no signal. Dropy now compares each frame's bytes on the capture queue (about 0.6 ms at the medium stream size) and drops identical frames before the main thread. After 30 unchanged frames it captures at 10 fps, and the first change restores 60 fps.
  - Static TextEdit: 855 of 857 frames were skipped before the adaptive rate was added. The CPU percentages recorded in this check came from the Sampler build that under-reported CPU about 42× (see the correction above) and are not used. TextEdit's blinking caret legitimately switches it back to full rate about once a second.
- **Most of the GPU cost was the panel's shadow.** With the overlay open and nothing captured, system GPU utilization was 31%. Without the panel shadow it was **4%**, and it was also low when Dropy did not activate itself. Plain test windows added nothing. The panel now has no shadow, a hairline border instead, and no tree masks.
- **Closed overlay recorded low wakeups:** 0.3 wakeups/s and 11 MB, measured with the pointer still. Its recorded CPU percentage came from the under-reporting Sampler; the 2026-09-29 run below re-measured it. Hover and click now use a tracking-area panel over the notch instead of global event monitors, so pointer movement elsewhere no longer wakes Dropy on notched screens. Its cost while the pointer moves has not been measured yet.
- **Presentation latency did not move.** Drawing immediately instead of through `setNeedsDisplay`, and using two drawables, left callback-to-screen at about 25–42 ms p50. That looks like the window compositor's floor for a windowed app, not Dropy's queueing.
- **Not yet re-measured:** a full benchmark after these changes. The only run attempted had the screen lock during the static and scroll phases (streams reported `suspended`), so those results were discarded.

## Coordinated benchmark, 2026-09-29

`Scripts/benchmark-phases.sh 30`: one session, the same two disposable Electron 43.2.0 fixture windows throughout (520×380 pt, `static.html` and `animation.html` side by side, throwaway profiles), measured without Dropy, with Dropy running but the overlay closed, with the overlay open on the static page, and open on the animating page. Overlay medium, fit, 1040×760 stream. Dropy selected each window by exact ID. The desktop lock was held and no input had occurred for 35 minutes. Report: [run 2](benchmarks/2026-09-29-coordinated-phases.md) (used below), [run 1](benchmarks/2026-09-29-coordinated-phases-run1.md) (same script, 4 minutes earlier; its closed row shows "( unchanged)" from a report-formatting bug fixed before run 2, and its raw samples are complete).

**The Mac was not idle.** WindowServer used about 45% CPU without Dropy, and a macOS `BackgroundShortcutRunner` (63–67%) and Cloudflare WARP (~19%) were running. Those belong to the person's setup and were left alone. As in the first baseline, read these as a loaded-system measurement.

| Phase | Dropy CPU mean / p95 | Footprint | Interrupt wakeups | WindowServer CPU | GPU util mean | Complete frames/s | Presented / not | Frame age p50 / p95 / p99 (ms) |
|---|---|---|---|---|---|---|---|---|
| Dropy not running | — | — | — | 45.4% | 22.7% | — | — | — |
| Overlay closed | 0.0% / 0.0% | 12.5 MB | 0.2/s | 45.0% | 23.4% | — | — | — |
| Open, source unchanged | 4.3% / 6.3% | 30.6 MB | 2.1/s | 44.6% | 24.5% | 27.1 (936 of 976 unchanged) | 42 / 48 | 43.3 / 100.9 / 103.7 |
| Open, source animating | 10.8% / 11.5% | 30.9 MB | 1.5/s | 47.2% | 26.7% | 57.4 | 2014 / 1 | 41.4 / 50.3 / 51.3 |

Run 1 agreed on CPU (idle 4.1%, active 11.0%), footprint and GPU, and differed in frame age: active p50 25.1 / p95 34.0 ms and idle p50 34.0 / p95 68.3 ms. This matches the earlier observation that presentation lands one or two refreshes after the callback, varying between runs.

Findings:

1. **Closed costs nothing measurable:** 0.0% CPU, 0.2 wakeups/s, 12.5 MB, and no GPU change beyond noise (+0.7 points).
2. **Capture adds little GPU on this path:** +1.8 points for an unchanged source and +4.0 for a 60 fps one, far below the 22–36 points of the first baseline (the panel shadow, since removed).
3. **An unchanged source is not yet cheap enough.** Byte-identical frames are skipped (936 of 976), but the stream switched between the 10 fps idle rate and 60 fps 41 times in 36 s, so it averaged 27 frames/s and 4.3% CPU against a 2% budget. So the captured image changes about once a second although the page is static; what changes (Chromium compositor output, window chrome) is not yet identified. The renderer also reported 48 not-presented against 42 presented frames in that phase, with frame age up to 104 ms. The cause is not yet known.
4. **A 60 fps source fits the CPU budget** (10.8% ≤ 12%) and presented 2014 of 2015 frames, but its frame-age p95 (50.3 ms) is at the 50 ms budget in run 2 and well under it in run 1.

## PR #30 review measurements

[Review rerun](benchmarks/2026-09-29-pr30-review.md): unchanged source **1.9% CPU**, 10.8 complete frames/s, one switch to idle and no switch back; all three forwarded frames presented. Active source **10.9% CPU**, 57.5 complete frames/s, frame-age p95 **34.0 ms**, 2028 presented and no final not-presented frames. Closed overlay: 0.0% CPU. The Mac still had unrelated background load; this is a loaded-system comparison, not a quiet-system release validation.

The static source's rate reconfiguration produced a changed frame, which previously immediately requested full rate and caused another change. Rate hysteresis now requires two consecutive changed samples to resume full rate; every changed frame still reaches the renderer immediately. An isolated static update stays at 10 fps, while continuing motion resumes 60 fps within two idle sampling intervals (up to roughly 200 ms). Byte-exact comparison and the original shader are retained; shadow exclusion and alpha-only comparison did not solve the oscillation and were removed.

`notPresented` now counts final frame outcomes once. Zero-time drawable attempts are counted separately as `drawableMisses`; retrying and later successfully showing the same frame cannot count it both shown and unshown. This corrects the earlier static presentation-budget failure. Idle frame-age p95 remains **100.4 ms**, based on only three changed frames, above the provisional 50 ms target; idle response latency and quiet-system replication remain M4 work.

## Idle input-to-visible latency trace, 2026-09-30

Measurement only; the pipeline and the provisional 50 ms frame-age target are unchanged. `DROPY_DEBUG_FRAME_TRACE=1` (off by default) logs, per forwarded frame, the time spent in each stage: `capture` (ScreenCaptureKit display time to Dropy's callback), `compare` (identical-frame check), `forward` (mailbox), `main` (hand-off to the main thread), `draw` (delivery to the commit of the draw that was finally shown, so drawable misses and their retries land here), `compose` (commit to on-glass), plus each draw's outcome and the time since the last input Dropy sent. `Scripts/latency-trace.sh 20 3` previews the disposable Electron fixture on the static text page, waits 10 s, then clicks the page's Press button through the preview 20 times, 3 s apart, so capture is back at its idle 10 fps before every click. `bun Scripts/bench/latency-summary.ts <log>` groups frames. Three runs on the same Mac, same load as above:

| Run | Response frame age p50 / p95 | Input → presented p50 / p95 | Input → captured p50 | draw p50 / p95 | compose p50 / p95 | Drawable misses per response frame |
|---|---|---|---|---|---|---|
| [1](benchmarks/2026-09-30-latency-trace-run1.md) | 60.9 / 106.9 | 135.8 / 188.4 | 74.5 | 30.6 / 57.0 | 30.3 / 49.0 | 43 in 20 |
| [2](benchmarks/2026-09-30-latency-trace-run2.md) | 63.1 / 107.1 | 133.7 / 183.8 | 65.5 | 31.6 / 57.0 | 30.6 / 49.0 | 42 in 20 |
| [3](benchmarks/2026-09-30-latency-trace-run3.md) | 60.6 / 81.5 | 124.6 / 152.9 | 63.7 | 30.5 / 45.0 | 30.0 / 35.6 | 39 in 20 |

Raw per-frame lines: `docs/benchmarks/raw/2026-09-30-latency-run{1,2,3}/`. Findings:

1. **The idle frame age is drawable misses, not capture or hand-off.** Capture, comparison, forwarding and main-thread delivery together take about 1 ms. The first frame drawn after an idle period is committed at once, but its drawable is reported never shown; so is the retry about 15 ms later; the third drawable is shown (run 3 draw log: `+0.1:miss,+16.1:miss,+33.3:shown` in 18 of 20 clicks; one click had no miss, one had three). The layer keeps two drawables (`maximumDrawableCount = 2`), so exactly the pooled drawables fail. Follow-up frames while the source keeps changing show no misses (draw p50 0.4 ms). This reproduces PR #30's idle frame-age p95 of about 100 ms.
2. **Compose is about two refreshes** (p50 30 ms) on every shown frame, idle or not, as in the first baseline.
3. **Input to capture is 64–75 ms at p50**: the app's own handling plus the idle 10 fps capture interval (up to 100 ms). The capture-rate hysteresis is therefore also on the input path; it should not be changed without re-measuring idle CPU.
4. **Idle CPU with tracing off**: 2.3% in one [check](benchmarks/2026-09-30-idle-cpu-check.md) at the same 10.8 frames/s idle rate, against 1.9% in the PR #30 review run. One run on a loaded Mac cannot separate a regression from noise; the tracing hooks are a static flag test per stage when off.

Next (M4): test one hypothesis at a time against this trace, for example why pooled drawables are dropped after idle (a `CAMetalLayer` drawable count or presentation mode), and keep a change only if the response-frame misses disappear without raising idle CPU.

## Provisional budgets

These come from the baseline above and are **not yet release gates**. They should be confirmed with at least five runs per workload on an idle system and on a second Mac model before they gate anything.

| Metric (per supported workload) | Provisional budget | Baseline status |
|---|---|---|
| Streams running after close | 0 (hard gate) | Pass |
| `captureToCallback` p99 | ≤ 10 ms | Pass |
| `frameAge` p95 | ≤ 50 ms | Mixed (35–59 ms; 2026-09-29 active 34.0 and 50.3 ms, idle 68–101 ms) |
| Frames presented | ≥ 95% of those sent to the renderer | Review rerun passes (idle 3/3, active 2028/2028); earlier static failure counted retry attempts as frames |
| Warm reveal p95 | ≤ 300 ms | Pass (261 ms) |
| Cold reveal | ≤ 600 ms | Mixed (426–775 ms) |
| Dropy CPU mean while previewing at 60 fps | ≤ 12% | Pass (10.8–11.0%, 2026-09-29) |
| Dropy CPU when the source is unchanged | ≤ 2% | Review rerun passes at 1.9%; quiet-system replication remains open |
| Added system GPU utilization | ≤ 20 points | Pass (+1.8 unchanged, +4.0 at 60 fps, 2026-09-29) |
| Dropy footprint | ≤ 64 MB | Pass (≤ 37 MB) |
| Dropy CPU with the overlay closed | ≈ 0% | Pass (0.0%, 0.2 wakeups/s, pointer still, 2026-09-29) |

Not covered yet: input-to-updated-frame (M3), WindowServer wakeups and footprint (need `powermetrics`), energy impact, a real media-decoder workload, and multi-display or full-screen placements.
