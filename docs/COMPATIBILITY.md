# Compatibility observations

This is a **development observation log**, not a supported-app list. A green capture image does not mean the app is interactive inside Dropy. Results need a Dropy revision, macOS version, target app version, display configuration and tested workflow before they can become release support claims.

## Verified capability matrix (2026-09-29)

M2 MacBook Air (`Mac14,2`), macOS 27.0 (26A428), built-in display only, one person-free session on one desktop plus a second desktop for the other-desktop condition. "Verified" means every recorded trial passed with another window of the app key *and* with the app inactive, no trial reached the decoy window, and the route has no side effect beyond the target becoming key inside its own app (see [feasibility](FEASIBILITY.md) and `InputCapabilities`). These are the only capabilities `Resources/InputEvidence.json` grants; every other app and macOS version is view-only.

**Input through the interactive preview (beta)**

| Target | Click | Scroll | Typing (committed text) | Shortcuts, editing keys, IME, drag, right-click | Evidence |
|---|---|---|---|---|---|
| AppKit input fixture | visible, covered, parked, other desktop, minimized | same | same | refused | [probe](input-probe/2026-09-29b-fixture.md), [end to end](device-checks/2026-09-29-interactive-routing.md) |
| TextEdit 1.21 | visible, parked (caret placement) | visible, parked | visible, parked | refused | [probe](input-probe/2026-09-29b-apps.md), [end to end](device-checks/2026-09-29-interactive-routing.md) |
| Safari 27.0 | **not verified** (no effect in page text) | visible, parked | **not verified** | refused | [probe](input-probe/2026-09-29b-apps.md) |
| Electron 43.2.0 fixture (Chromium 150) | visible, covered, parked, other desktop, minimized, on **pressable elements only** (Accessibility press) | visible, covered, parked (window-targeted event) | **not verified**: no route reached a non-key window's field | refused | [probe](input-probe/2026-09-29c-electron-fixture.md), [end to end](device-checks/2026-09-29-interactive-routing.md) |

Electron specifics, from 192 trials against a disposable two-window app with a throwaway profile:

- Chromium builds its Accessibility tree only on request. The trials ran with `AXManualAccessibility` switched on, so the evidence says so (`requiresManualAccessibility`) and Dropy switches it on for that app when interaction starts; the tree then takes about 2 s to appear, and earlier clicks say "Nothing to click there".
- A window-targeted click on a non-key Electron window only makes it key (Chromium does not click through), so clicks use the Accessibility press. Clicks on non-pressable content (text selection, links without a press action, canvas) are not verified.
- Window-targeted scrolling passed visible, covered and parked, but did nothing on another desktop or minimized: Chromium does not process wheel events for a window it considers hidden.
- `AXSelectedText` insertion changed nothing in an `<input>`. Process and window-targeted key events went to the key window (**wrong window** in every non-key trial), as with AppKit. Typing is refused.
- Menu shortcuts through Accessibility or events acted on the key window (**wrong window**). Refused.

**Routing safety** ([report](device-checks/2026-09-29-interactive-routing.md)): the preview maps a point only through the frame actually drawn and only when that frame's stream geometry matches the source's current size and the current selection (`PreviewInputGate`); the router re-checks the live window size. Device checks passed for a click mapped at a stale size, a real source resize between mapping and sending (click and scroll), 25 rapid source switches (no typing target survives), a replaced text field (stale element refused, not retried), a hidden source, and quit/relaunch (the old identity is refused for click, scroll and typing, and the relaunched instance is untouched). Pointer, frontmost app and desktop never changed.

**PR #30 review:** mappings are published only after a successful drawable presentation; pending frames cannot impersonate a drawn frame. Resize/mode changes revoke the mapping until redrawn. Source size is recovered from each sample's ScreenCaptureKit metadata, so old frames cannot be relabelled by a completed reconfiguration, including proportional resizes with identical output dimensions. Continuous animation retains the latest confirmed mapping; the Electron animation-click regression passes. Device sessions use a kernel lock before builds or backup-directory publication, and restore preferences before releasing ownership. Full results: [review](device-checks/2026-09-29-pr30-review.md).

**Containment and recovery** (`Scripts/device-checks.sh`)

| Target | offscreen | parked | minimize | hideApp | Your move wins | Crash while parked | Report |
|---|---|---|---|---|---|---|---|
| TextEdit 1.21 | restored; 1.3% visible, capture live | restored; 0.000 uncovered, capture live | restored; capture pauses | restored; capture pauses | kept | restored from journal | [2026-09-29](device-checks/2026-09-29-recovery-textedit.md) |
| Electron 43.2.0 fixture | restored; 2.4% visible, capture live (354 frames shown) | restored; 0.000 uncovered, capture live | restored; capture pauses | restored; capture pauses | kept | restored from journal | [2026-09-29](device-checks/2026-09-29-recovery-electron.md) |

Reviewer recovery reruns: [Electron](device-checks/2026-09-29-pr30-review-electron.md) passed eight checks, including normal/crash parked recovery on another desktop. [TextEdit](device-checks/2026-09-29-pr30-review-textedit.md) passed the six standard checks; its added cross-desktop setup could not switch desktops and is recorded NOT RUN. Parking remains experimental.

Not verified anywhere: IME composition, dead keys, editing keys, shortcuts, context menus, sheets and file dialogs, drag and drop, hover, momentum scrolling, full-screen and Stage Manager sources, multi-display, a real third-party Electron app (only the disposable fixture was tested, so personal workspaces were never driven). Parking remains experimental.

## Observation log

| Dropy revision | Environment | Target | Observed workflow | Result | Original window |
|---|---|---|---|---|---|
| Initial native build | M2 MacBook, macOS 27.0, built-in display | Spotify (version not recorded) | Select running window; show live pixels in Metal preview | Visual preview passed; input not enabled | Visible elsewhere |
| Initial native build | Same device | tldraw offline (version not recorded) | Select running window; show live pixels in Metal preview | Visual preview passed; input not enabled | Visible elsewhere |
| Controlled test harness | Same device | Small AppKit test app | Move a specially unconstrained window entirely off-screen; capture it; click an AX-exposed button through a mirror | Narrow controlled check passed | Out of sight by test-only subclass |
| Capture lifecycle branch (#2, #3) | Same device, display asleep for part of the run | TextEdit 1.21 (AppKit), two documents | Exact identity across resize, move, minimize, app hide, close and quit/relaunch with the same files; direct-open preview; minimize/restore; close; quit | Identities stayed distinct; relaunched documents never matched old selections; preview reported paused/viewing, window closed and target quit | Visible elsewhere |
| Same | Same | Safari 27.0 (WebKit), two `about:blank` windows | Same-title windows; resize, close one, quit | Resolution stayed exact; picker now labels them "(1 of 2)" and "(2 of 2)" | Visible elsewhere |
| Same | Same | ChatGPT 26.917.71314 (`com.openai.codex`) | Picker listing | A floating layer-3 panel with the main window's title was listed as a second identical entry; now excluded | Visible elsewhere |
| Lifecycle validation (#3) | Same device | TextEdit 1.21, two documents | `DROPY_DEBUG_ALTERNATE` runs of 40–201 switches with 0–150 ms random gaps; source close after switching | Always ended on the expected window; at most one running stream; zero after close; final preview starts 150–330 ms after the last switch (was 2–5 s before coalescing) | Visible elsewhere |
| Same | Same | Same | System "Stop sharing" control during capture | Stream stopped with `-3817`; no automatic restart; preview cleared after a renderer fix; TextEdit stayed visible, unminimized and could be brought to the front | Visible elsewhere |
| Same | Same | — | Revoke Screen Recording during capture | **Not tested**: Dropy's own grant did not match the ad-hoc build, and revoking the terminal's grant was deferred | — |
| `384953d` | M2 MacBook Air, macOS 27.0, built-in display | TextEdit 1.21 | Preview while an opaque window fully covers the source for ~165 s; edit the document while covered | Stream stayed live (2,202 complete frames, idle rate engaged and recovered 47 times); edits while covered reached the preview; clean stop. In one earlier run TextEdit exited ~107 s into the cover; Dropy reported target quit and cleared the preview. Not reproduced in two later runs (with and without Dropy), cause unknown | Covered by a test window |

TextEdit's window can stay in the WindowServer after its document closes while the display is asleep; Dropy correctly keeps it as the source until it disappears. All other apps and workflows are **untested**. A protected or unavailable capture region will be reported as a platform limitation rather than bypassed. The [roadmap](../ROADMAP.md) defines the matrix needed before any *interactive* compatibility level is offered.
