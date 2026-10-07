# Stage spike results (Phase 0)

Run on 7 October 2026: M2 MacBook Air, macOS 27.0.1 (26A434), built-in display only (1710 × 1112 pt, 2×, 60 Hz), three desktops, "Displays have separate Spaces" on (the default). Tool: `Scripts/bench/StageSpike` (throwaway; scenario files of commands against a Dropy-owned virtual display). The Preview measurements used Dropy's own capture metrics (`DROPY_DEBUG_WINDOW_ID`, `DROPY_DEBUG_CYCLES`). Test windows were a scratch TextEdit document and a Safari window on `Scripts/bench/animation.html`. Both were closed afterwards, and the person's Dropy settings were restored.

Plan: [2026-10-07-interaction-engine-plan.md](2026-10-07-interaction-engine-plan.md).

**Verdict:** S1, S2, S3, S5 and S6 pass. S4 passes on mechanics, but its feel has not been tried by a person yet. **Go: build the Stage (Phase 2), then Live mode (Phase 4).**

## S1: the Stage

| Check | Result |
|---|---|
| Create a 1200 × 800 pt HiDPI virtual display at 60 Hz | Appeared in 343–399 ms as 2400 × 1600 px at scale 2, with its own desktop. In one of seven runs, `NSScreen` had still not listed it after 3.2 s, although it worked right after; Dropy must wait on the display-reconfiguration callback rather than poll a timeout |
| Arrangement | Placed at the main display's bottom-right **corner only** (`1710,1112`). macOS kept it there: no shared edge, so the pointer can only reach it diagonally |
| Other windows moved by creating, arranging or releasing it | **None** |
| Release | Gone 52 ms after the object was released |
| Crash with a window on the Stage (`abort()`) | The window survived. macOS moved it to the main display at its earlier position, **on desktop 1**, not the desktop the person was on. Dropy's recovery must restore the desktop too, by hopping the window through a fresh Stage (S2) |

## S2: moving windows

| Move | Result |
|---|---|
| Main → Stage → notch position → back (same desktop) | Every move was confirmed by readback in 0–93 ms. Resizing works on the Stage. The window joined the Stage's desktop, then the main display's current desktop |
| **From another desktop**: window on desktop 3, person on desktop 120. Move it to the Stage, then to the main display | Reached through the app's main window by exact ID (`AXWindows` lists only the current desktop). It moved onto the Stage, then **landed on desktop 120, the one the person is on**. Pulling a window across desktops works with public Accessibility moves, via the Stage |
| Back home the same way | Desktop 120 → Stage → desktop 3, exact frame |

## S3 and S6: streaming from the Stage, and covering it

Safari animating at display rate, previewed by Dropy for 7 s in each placement:

| Placement | Changed frames/s | Frame age p50 / p95 | Safari CPU | WindowServer CPU |
|---|---|---|---|---|
| On the person's screen | 57.7 | 42.1 / 50.5 ms | 8.7% | 45.7% |
| On the Stage, uncovered | **58.2** | **25.2 / 32.9 ms** | 8.6% | 45.9% |
| On the Stage, under an opaque curtain | about 0.5 (91 of 95 frames unchanged) | — | **1.9%** | **35.9%** |

A window on the Stage is drawn at full speed and streams well inside the 50 ms budget. Covering the Stage makes the app throttle itself, as AppKit's occlusion rules predict. That saves about 7 points of Safari CPU and about 10 points of WindowServer CPU. The WindowServer baseline is high on this Mac because of unrelated background load; compare the differences, not the absolute numbers.

## S4: pointer, popups and cursor (mechanics)

| Check | Result |
|---|---|
| Warp the pointer onto the Stage and back, re-associating at once | Exact position, on the right display, no hold-off |
| Cursor image from another app (`NSCursor.currentSystem`, deprecated since macOS 15) | **Works on 27.0.1**: an I-beam (23 × 22) over TextEdit's text on the Stage, the arrow back on the main display |
| Right-click on the Stage | TextEdit's context menu opened **on the Stage** beside the click (layer 101), so a stream of the Stage shows it. Esc closed it |
| **Not yet tried by a person** | How the hand-off feels while moving, drag-out to another app, real menu tracking, 100 crossings, shake-to-locate. These belong to the Phase 4 prototype, judged by the person |

## S5: focus and desktops

| Check | Result |
|---|---|
| Bring the staged app forward from another desktop | Frontmost in 18 ms; desktop unchanged |
| Bring the staged app forward **while another app is full screen** on the main display | Frontmost in 36 ms; **still on the full-screen space**. Live mode over full-screen apps is viable |
| Bring it forward on the same desktop | 7 ms, unchanged |
| Stage Manager | Not tested (off on this Mac) |

## What changes in the plan

1. **Pinned apps live on the Stage between openings,** and the other-desktop problem is solved with public moves. Native opening becomes: Stage → notch on whatever desktop the person is on.
2. **Crash recovery must restore the desktop as well as the frame:** after a crash, macOS puts staged windows on desktop 1. The journal already has the frame, and needs the original desktop too (S1).
3. **Find windows by exact ID through the app's main and focused windows,** as `WindowPlacer.find` already does. A window off the current desktop is not in `AXWindows` (S2).
4. **Wait for the display to be reported,** not a fixed time, when creating the Stage (S1).
5. **Cover the Stage whenever nothing on it is shown** (S6).
