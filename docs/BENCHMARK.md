# Capture benchmark

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
caffeinate -d ./Scripts/benchmark.sh 20            # all workloads, 20 s per phase
./Scripts/benchmark.sh 20 animation                # one workload
env DROPY_DEBUG_CYCLES=20,800 DROPY_DEBUG_QUIT_AFTER=60 \
  .build/local/Dropy.app/Contents/MacOS/Dropy --show   # cycles, with direct-open set to a running app
```

Reports are written to `.build/local/benchmark-<timestamp>.md`.

## Baseline, 2026-09-26

Setup: M2 MacBook Air (`Mac14,2`), macOS 27.0 (26A428), built-in 2560×1664 Retina display, overlay at the medium size (1176×705 stream), fit mode, Dropy `18ad4dd`. Raw reports: [run 1](benchmarks/2026-09-26-run1-aerial-wallpaper.md) (Aerial wallpaper) and [run 2](benchmarks/2026-09-26-run2-still-wallpaper.md) (still wallpaper).

**The system was not idle.** WindowServer used about 44% CPU with or without Dropy. Cloudflare WARP (about 31%), `mediaanalysisd` (about 18%) and browser helper processes playing media were running. Swapping the Aerial wallpaper for a still one changed nothing measurable. Treat these results as a loaded-system baseline.

| Workload | Run | Dropy CPU mean | GPU util without → with Dropy | Complete frames/s | Not presented | Frame age p50 / p95 / p99 (ms) | Cold reveal |
|---|---|---|---|---|---|---|---|
| static | 1 | 9.7% | 11 → 44% | 57.6 | 1 of 1427 | 26.9 / 36.0 / 41.0 | 468 ms |
| static | 2 | 11.2% | 12 → 45% | 57.5 | 2 of 1429 | 42.1 / 51.9 / 52.7 | 440 ms |
| scroll | 1 | 10.0% | 18 → 47% | 57.7 | 2 of 1434 | 28.4 / 35.4 / 37.3 | 505 ms |
| scroll | 2 | 11.7% | 18 → 48% | 57.7 | 2 of 1423 | 40.2 / 51.9 / 53.0 | 559 ms |
| animation | 1 | 9.1% | 33 → 55% | 56.0 | **697 of 1361** | 48.0 / 59.1 / 65.5 | 775 ms |
| animation | 2 | 12.0% | 32 → 58% | 57.8 | 4 of 1426 | 29.8 / 36.4 / 41.1 | 673 ms |

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

## Provisional budgets

These come from the baseline above and are **not yet release gates**. They should be confirmed with at least five runs per workload on an idle system and on a second Mac model before they gate anything.

| Metric (per supported workload) | Provisional budget | Baseline status |
|---|---|---|
| Streams running after close | 0 (hard gate) | Pass |
| `captureToCallback` p99 | ≤ 10 ms | Pass |
| `frameAge` p95 | ≤ 50 ms | Mixed (35–59 ms) |
| Frames presented | ≥ 95% of those sent to the renderer | Fails once (animation run 1) |
| Warm reveal p95 | ≤ 300 ms | Pass (261 ms) |
| Cold reveal | ≤ 600 ms | Mixed (426–775 ms) |
| Dropy CPU mean while previewing at 60 fps | ≤ 12% | Borderline (9–12%) |
| Dropy CPU when the source is unchanged | ≤ 2% | Not measurable yet (finding 3) |
| Added system GPU utilization | ≤ 20 points | Fails (22–36) |
| Dropy footprint | ≤ 64 MB | Pass (≤ 37 MB) |

Not covered yet: input-to-updated-frame (M3), WindowServer wakeups and footprint (need `powermetrics`), energy impact, a real media-decoder workload, and multi-display or full-screen placements.
