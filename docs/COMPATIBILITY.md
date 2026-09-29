# Compatibility observations

This is a **development observation log**, not a supported-app list. A green capture image does not mean the app is interactive inside Dropy. Results need a Dropy revision, macOS version, target app version, display configuration and tested workflow before they can become release support claims.

## M3 workflow contract

This is the written contract that M3's exit condition refers to. Results below are judged against it; nothing is promoted by a demo.

**Support levels**, per app, app version, macOS major version, input kind, element class and source condition:

| Level | Meaning |
|---|---|
| View-only | Live pixels; every input is refused with a reason on screen |
| Clickable (class) | A click on an element of that class (pressable, text, other) reaches the exact element in the exact window |
| Scrollable | A wheel scroll moves only the scroll area under the pointer in the exact window |
| Typable (field class) | Committed characters are inserted at the field's own caret or replace its selection, in the exact field, with the app's own input events and undo |

**Source conditions**: visible, covered by another window, parked (moved beyond the displays behind a Dropy tab), minimized, on another desktop, app hidden. A level holds only for the conditions in which it was verified. When the source cannot be tied to the selected window (closed, relaunched, resized mid-send, stale element, no drawn frame, another desktop without evidence, app hidden, Accessibility not granted), input is refused and the preview says why.

**A trial passes only if all of these hold**: the intended effect happened, exactly (text and caret, not "something changed"), in the target element of window A; the decoy window B of the same app neither changed nor received the event; nothing else changed except, at most, A becoming key inside its own inactive app; the pointer did not move; no modifier key or mouse button was left down; the frontmost app and the active desktop did not change. A trial whose setup could not be verified (focus state, cover, parking, minimize, desktop) is **NOT RUN**, never a pass.

**A level is verified** for a condition when every trial passed with another window of the app key *and* with the app in the background, with no wrong-window trial in any repeat; and, for any level shipped in the preview, an end-to-end check with real HID input on Dropy's preview (`Scripts/interactive-checks.sh`) passed in at least the visible condition. Any wrong-window observation disqualifies that route for that kind, class and condition.

**Containment contract**, per app: the four placement modes restore the window exactly; a move made by the person during a placement is kept; a placement journal left by a killed Dropy is restored on the next launch, including with the source on another desktop; and while parked the capture keeps presenting the source's changes. Minimize and hide pause capture, and the preview says paused.

**Always refused until exact-target evidence exists**: editing keys (arrows, delete, return), shortcuts, input-method composition, dead keys, context menus, drag and drop, hover, momentum and modified scrolling, modified and multi-clicks, and any sheet, menu or dialog outside the captured window. Each refusal must be visible and must reach neither window.

**Failures**: any wrong-window effect or delivery, focus theft from Dropy, pointer motion, a held key or button, a source window not restored or lost, a desktop change, and a report that calls a skipped check passed.

**M3 exit condition, made concrete**: one named app per toolkit (AppKit: TextEdit; WebKit: Safari; Chromium/Electron: a third-party Electron app; media: a media player) meets the containment contract and has at least click and scroll verified in the visible *and* the parked condition, with every other workflow refused as above. A toolkit represented only by Dropy's own disposable fixture does not count.

### M3 exit evaluation (2026-09-30)

| Toolkit | Named app | Containment contract | Click, visible / parked | Scroll, visible / parked | Typing | Verdict |
|---|---|---|---|---|---|---|
| AppKit | TextEdit 1.21 | **Pass**: four modes, your move wins, crash, and parked recovery on another desktop (normal and crash) | Pass / pass (text: caret) | Pass / pass | Pass / pass | **Meets the contract** |
| WebKit | Safari 27.0 | **Pass** (six checks); parked capture **throttled** to about 5 fps while off-screen with a sliver visible stays at 60 | Pass / pass (page buttons only) | Pass / pass | **Refused** (no safe route) | Meets click and scroll; typing refused |
| Chromium/Electron | Visual Studio Code 1.139.1 (scratch) | **Not run** | **Unreliable** (caret, 6 of 8 conditions) | **No route measured** (no Accessibility scroll bar) | **Refused** (keys reach window B) | **Fails**: view-only |
| Media | QuickTime Player (generated movie) | **Pass** (six checks); parked capture throttled to about 10 fps | **No route**: its window exposes no playback controls to Accessibility, and playback state cannot be read without Apple Events | No scroll area | Refused | **Fails**: view-only |

**M3 is not complete.** Two toolkits have no third-party app with verified click and scroll, and every parked source that animates is throttled by its app once no pixel of it is visible (Safari about 5 fps, QuickTime about 10, the Electron fixture about 22, against about 60 off-screen with a 1–2% sliver visible). The disposable Electron fixture proves the routes work in Chromium, but by the contract it does not count for the toolkit.

## Verified capability matrix (2026-09-30)

M2 MacBook Air (`Mac14,2`), macOS 27.0 (26A428), built-in display only, one person-free session on one desktop plus a second desktop for the other-desktop condition. "Verified" means every recorded trial passed with another window of the app key *and* with the app inactive, no trial reached the decoy window, and the route has no side effect beyond the target becoming key inside its own app (see [feasibility](FEASIBILITY.md) and `InputCapabilities`). These are the only capabilities `Resources/InputEvidence.json` grants; every other app and macOS version is view-only. Since 2026-09-30, click evidence is also **per element class** (`InputTargetClass`: pressable, text, other): the router classifies the element under the pointer and sends only if a route is verified for that class. Trials recorded without a class count for every class, so they can only make a class fail; only the disposable AppKit fixture's clicks are unclassified.

**Input through the interactive preview (beta)**

| Target | Click | Scroll | Typing (committed text) | Shortcuts, editing keys, IME, drag, right-click | Evidence |
|---|---|---|---|---|---|
| AppKit input fixture | visible, covered, parked, other desktop, minimized (any element) | same | same | refused | [probe](input-probe/2026-09-29b-fixture.md), [end to end](device-checks/2026-09-30-interactive-routing.md) |
| TextEdit 1.21 | visible, parked: **text** (caret placement) only | visible, parked | visible, parked | refused | [probe](input-probe/2026-09-29b-apps.md), [end to end](device-checks/2026-09-30-interactive-routing.md) |
| Safari 27.0 | visible, covered, parked, minimized: **page buttons** (Accessibility press) only; other desktop: passed with the app inactive, NOT RUN with window B key (after a desktop switch Safari is no longer frontmost), so not verified; caret placement **not verified** | visible, parked | **refused**: no safe route (see below) | refused | [text probe](input-probe/2026-09-30-safari-text.md), [probe](input-probe/2026-09-29b-apps.md), [end to end](device-checks/2026-09-30-interactive-routing.md) |
| Electron 43.2.0 fixture (Chromium 150) | visible, covered, parked, other desktop, minimized: **pressable elements** only (Accessibility press) | visible, covered, parked (window-targeted event) | **refused**: no safe route (see below) | refused | [probe](input-probe/2026-09-29c-electron-fixture.md), [text probe](input-probe/2026-09-30-electron-text.md), [end to end](device-checks/2026-09-30-interactive-routing.md) |
| Visual Studio Code 1.139.1 (scratch profile) | **view-only**: caret clicks inconsistent | **view-only**: no route | **view-only**: keys reach window B | refused | [probe](input-probe/2026-09-30-vscode.md) |
| QuickTime Player (generated movie) | **view-only**: no controls exposed to Accessibility | **view-only**: nothing to scroll | refused | refused | [containment](device-checks/2026-09-30-recovery-quicktime.md) |

Electron specifics, from 192 trials against a disposable two-window app with a throwaway profile:

- Chromium builds its Accessibility tree only on request. The trials ran with `AXManualAccessibility` switched on, so the evidence says so (`requiresManualAccessibility`) and Dropy switches it on for that app when interaction starts; the tree then takes about 2 s to appear, and earlier clicks say "Nothing to click there".
- A window-targeted click on a non-key Electron window only makes it key (Chromium does not click through), so clicks use the Accessibility press. Clicks on non-pressable content (text selection, links without a press action, canvas) are not verified.
- Window-targeted scrolling passed visible, covered and parked, but did nothing on another desktop or minimized: Chromium does not process wheel events for a window it considers hidden.
- `AXSelectedText` insertion changed nothing in an `<input>`. Process and window-targeted key events went to the key window (**wrong window** in every non-key trial), as with AppKit. Typing is refused.
- Menu shortcuts through Accessibility or events acted on the key window (**wrong window**). Refused.

**Text semantics (2026-09-30).** `Scripts/text-probe.sh` loads `Scripts/bench/text.html` into window A and decoy B and types into a prefilled input with the caret in the middle, over a selection, inside line 2 of a textarea and inside a contenteditable, with A key (control), B key, or the app in the background, and A visible, covered, parked, minimized or on another desktop (Electron only). A pass needs the exact text and caret in A's field, an input event in A, A's other fields and all of B unchanged, and no focus, desktop, pointer or held-key change; undo is measured afterwards with the page's own undo.

| Route | Electron fixture, A not key | Safari, A not key |
|---|---|---|
| `AXSelectedText` insert | no effect in any field | no effect in any field |
| Rewrite the field's `AXValue` at its selection | **wrong position**: Chromium reports the selection as 0 when the window is not key, so text went to the start (`dx7alpha beta`); the input event has no `inputType`, a `change` event fires, undo does not take it back; contenteditable unchanged | input: **the text went into the contenteditable** that held the document selection, not the target field; selection and textarea cases unchanged; contenteditable alone was correct with working undo |
| Key events addressed to A (window-targeted) | **wrong window** (B edited) in every condition | no effect anywhere |

With A key and its field focused, both the value rewrite (Electron: not in contenteditable) and key events typed correctly. That is the "works only when the source is focused" case, not exact-window typing, so it is not a route. Earlier empty-field trials of the value rewrite ([2026-09-29d](input-probe/2026-09-29d-electron-typing.md)) passed only because the start and the end of an empty field coincide. **Typing stays refused for Electron and Safari.** A safe route needs an API that inserts at a caret the app itself reports for a non-key window; none of the tested ones do.

**Routing safety** ([report](device-checks/2026-09-29-interactive-routing.md)): the preview maps a point only through the frame actually drawn and only when that frame's stream geometry matches the source's current size and the current selection (`PreviewInputGate`); the router re-checks the live window size. Device checks passed for a click mapped at a stale size, a real source resize between mapping and sending (click and scroll), 25 rapid source switches (no typing target survives), a replaced text field (stale element refused, not retried), a hidden source, and quit/relaunch (the old identity is refused for click, scroll and typing, and the relaunched instance is untouched). Pointer, frontmost app and desktop never changed.

**PR #30 review:** mappings are published only after a successful drawable presentation; pending frames cannot impersonate a drawn frame. Resize/mode changes revoke the mapping until redrawn. Source size is recovered from each sample's ScreenCaptureKit metadata, so old frames cannot be relabelled by a completed reconfiguration, including proportional resizes with identical output dimensions. Continuous animation retains the latest confirmed mapping; the Electron animation-click regression passes. Device sessions use a kernel lock before builds or backup-directory publication, and restore preferences before releasing ownership. Full results: [review](device-checks/2026-09-29-pr30-review.md).

**Containment and recovery** (`Scripts/device-checks.sh`)

| Target | offscreen | parked | minimize | hideApp | Your move wins | Crash while parked | Report |
|---|---|---|---|---|---|---|---|
| TextEdit 1.21 | restored; 1.3% visible, capture live | restored; 0.000 uncovered, capture live | restored; capture pauses | restored; capture pauses | kept | restored from journal | [2026-09-29](device-checks/2026-09-29-recovery-textedit.md) |
| Safari 27.0 (animating local page) | restored; 1.6% visible, capture live (361 frames shown) | restored; 0.000 uncovered; capture **throttled** (37 complete frames in the hold) | restored; capture pauses | restored; capture pauses | kept | restored from journal | [2026-09-30](device-checks/2026-09-30-recovery-safari.md) |
| QuickTime Player (generated 240 s movie, playing) | restored; 2.0% visible, capture live (192 shown) | restored; 0.000 uncovered; capture **throttled** (64 complete) | restored; capture pauses | restored; capture pauses | kept | restored from journal | [2026-09-30](device-checks/2026-09-30-recovery-quicktime.md) |
| TextEdit 1.21, source on another desktop | — | restored (normal and after `kill -9`); window on desktop 4 while desktop 24 active, recorded independently before each restore | — | — | — | restored from journal | [2026-09-29](device-checks/2026-09-29-textedit-other-desktop.md) |
| Electron 43.2.0 fixture | restored; 2.4% visible, capture live (354 frames shown) | restored; 0.000 uncovered, capture live | restored; capture pauses | restored; capture pauses | kept | restored from journal | [2026-09-29](device-checks/2026-09-29-recovery-electron.md) |

Reviewer recovery reruns: [Electron](device-checks/2026-09-29-pr30-review-electron.md) passed eight checks, including normal/crash parked recovery on another desktop. [TextEdit](device-checks/2026-09-29-pr30-review-textedit.md) passed the six standard checks; its cross-desktop setup could not switch desktops. The cause: Mission Control ignores a synthetic Control-arrow unless the arrow carries the numeric-pad and Fn flags a keyboard sets. With that fixed, the TextEdit cross-desktop run passed 8/8 (row above). Parking remains experimental.

**Refusals, end to end** (`Scripts/interactive-checks.sh`, input fixture, visible, real HID input on the preview): right-click, drag, Option-scroll, Command-K and the left-arrow and delete keys each reached neither window and showed a refusal in the preview. A double-click delivered its first click as an ordinary click (as a native app receives it) and refused the second; the check was corrected to expect exactly that. Permission loss: a router whose Accessibility trust check fails refuses click, scroll and typing, and sends nothing (`accessibilityNotGranted`, device regression with an injected check; the real permission was not revoked). Input methods are refused whenever the current input source is not a plain keyboard layout; that branch was not exercised on device, because switching the person's input source was out of scope.

Refused everywhere until exact-target evidence exists: typing outside TextEdit and the fixture, caret clicks outside TextEdit, clicks on non-pressable page content, IME composition, dead keys, editing keys, shortcuts, context menus, sheets and file dialogs, drag and drop, hover and momentum scrolling. Not tested: full-screen and Stage Manager sources, multi-display, Safari on another desktop (a foreign app's window cannot be moved between desktops from outside it), and any third-party app beyond the VS Code scratch instance. Parking remains experimental.

Test-hygiene incidents (2026-09-30): the scratch VS Code rewrote the shared `~/.vscode/argv.json` (a telemetry setting flips `enable-crash-reporter`); it was restored byte for byte and the script now backs it up and uses CLI flags instead. The same scratch instance's updater, which is shared with a person's install whatever the user-data directory, installed a VS Code update (1.136.1 → 1.139.1) into `/Applications` on quit despite `"update.mode": "none"`; that cannot be undone from here, and the script now warns if the installed version changes.

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
