# Feasibility status

## Observed in controlled local tests

- A borderless panel could occupy the MacBook top band and a separate AppKit window could be captured with ScreenCaptureKit.
- A captured frame's pixel buffer was IOSurface-backed. The native app rendered live Spotify and tldraw windows in a Metal preview after explicitly requesting BGRA output.
- A click in a controlled mirror panel invoked one Accessibility-exposed button in a separate test app.
- A specially configured test source window could sit fully off-screen, remain capturable, and accept that one Accessibility action. An ordinary `NSWindow` initially constrained its position so part remained visible. This does not establish a way to park arbitrary third-party windows.
- The native Dropy build currently shows live windows, but it does not forward interaction and it does not hide the original app window.

These checks were correctness observations, not frame-age, energy, battery or broad compatibility benchmarks. The current UI says **live preview** rather than *interactive app* for that reason.

## Source placement on ordinary windows (M2, first results)

TextEdit 1.21 on macOS 27.0 (M2 MacBook Air, built-in display), each placement undone through the journal. Mode results are from `DROPY_DEBUG_PLACEMENT`, run twice each. The clamp table comes from moving the window with Accessibility.

| Placement | Capture while placed | Visible on screen | Restored |
|---|---|---|---|
| Minimize | Stops (0 frames; preview paused) | Nothing | Yes, both runs |
| Hide app | Stops (0 frames; preview paused) | Nothing (but hides all of the app's windows) | Yes, both runs |
| Move off-screen, right | Continues (~110–200 frames in the hold) | 40 × 440 pt strip (5%) | Yes, both runs |
| Fully covered by another window | Continues (M1 check, ~165 s) | Nothing, but the cover occupies that screen area | Not needed |

AppKit clamps a moved foreign window so part of it stays reachable: 40 pt when pushed left or right, 118 pt when pushed below the screen, and it cannot go above the menu bar. The bottom-right corner leaves the smallest strip (40 × 118 pt, 1.3% for an 800 × 440 window), so off-screen placement now targets that corner. The corner target itself is not yet verified through the driver.

**Device-check run, 2026-09-28** (`Scripts/device-checks.sh`; raw report in [device-checks](device-checks/2026-09-28-textedit-safari.md)):

- **TextEdit, `parked`: live and fully out of sight.** The window moved to the bottom-right corner, a Dropy tab covered the 40 × 118 pt strip AppKit kept on screen (0.000 visible), capture continued (29 frames, 9 changes shown), and the window was restored exactly. The corner `offscreen` target left 1.3% visible, as predicted.
- TextEdit: a move made during a placement was kept (`keptUserChange`). Killing Dropy while the window was parked left a journal entry, and the next launch restored the window.
- **Safari (WebKit): not yet usable.** While off-screen it rendered 3 frames and then went idle, although the page animates continuously, so WebKit appears to stop rendering off-screen windows. After that move, Safari's Accessibility tree returned the application element as its main, focused and only window, so every later placement was refused. A freshly launched Safari stayed in that state.
- *(Superseded below.)* The session suspected that off-screen moves corrupt an app's Accessibility window list.

**Conclusion so far:** `parked` kept an AppKit window live and fully out of sight in one device run; WebKit did not keep rendering off-screen; and the Accessibility side effect of off-screen moves is unresolved. Next experiments: other toolkits (WebKit, Electron/Chromium, media), which may clamp differently, and a tiny Dropy window covering the leftover corner strip, since covered windows keep capturing.

During the session, Accessibility began returning invalid window elements for every app (an `AXApplication` or `AXScrollArea` role in the windows list), even though `AXIsProcessTrusted` still reported true. The exact-window lookup then failed and Dropy refused to place anything, which is the intended behaviour.

## Accessibility lookup failures are Space changes, not placement damage (2026-09-29)

On macOS 27.0 an app's `AXWindows` list contains only its windows on the **active Space**. When the person switches desktops, a source window on the previous desktop drops out of that list, which is then often empty (Finder keeps only its desktop `AXScrollArea`). The window server still lists the window, `AXMainWindow`/`AXFocusedWindow` still return it with its exact window ID, and setting its position through Accessibility still works on the other Space.

Evidence, from a disposable fixture app (`Scripts/bench/Fixture`) that moves its own window between Spaces and `WindowTool snapshot`, which classifies each miss (permission, non-window roles, stale elements, `_AXUIElementGetWindow` failure, other Space, unlisted on the active Space):

- Moving the fixture window to another Space removed it from `AXWindows` immediately; moving it back restored it. Finder, WhatsApp, ChatGPT and Discord showed the same empty or `AXScrollArea`-only list for their windows on another desktop in the same session.
- 105 attributed placement cycles (off-screen, corner, minimize, hide) on the fixture: 8 lookup failures, **every one** with the window's Space different from the active Space, because desktops were being switched during the run. There were no failures while the window was on the active Space, and no placement changed the window's Space.
- The 2026-09-29 TextEdit failure (`axWindows=[]` before minimize) matches this signature. The Safari `AXApplication`-as-window state from 2026-09-28 has not been reproduced and remains unexplained.

Changes: the exact lookup also considers the main and focused window (still matched by exact window ID, never by title or frame). A miss is diagnosed and logged, and only a closed window or an exited process settles a journal entry. Every other miss keeps the record, and `PlacementRecovery` retries with 1–30 s backoff and immediately on Space change, app activation and wake. Placement refuses windows that are not on screen, and the placement experiment requires a live preview.

Device checks (`ONLY=fixture Scripts/device-checks.sh`, [report](device-checks/2026-09-29-space-recovery.md)): parking the fixture and moving it to another desktop restored it there. With a second window as main, the restore deferred as `windowUnreachable(onOtherSpace)`, kept the journal and restored automatically once the window returned, including after Dropy was killed while the window was away. The same three checks **fail on `82e8911`** (`restore=pending`, no retry). Safari and Notion restored in every placement run in this session. TextEdit's remaining checks, user-move and crash recovery were not completed because its window was on another desktop during the run; that is now reported rather than misread.

`parked` remains experimental. A window that is neither main nor focused and sits on a desktop the person never revisits stays recorded, with advice in **Recover pending source windows…**.

## Exact-window input, first harness results (M3 #8, 2026-09-29)

`Scripts/input-probe.sh` drives a disposable two-window fixture (`Scripts/bench/InputFixture`). It sends typing, a click, a scroll and a menu shortcut to window A through each route while window B of the same app is key, or while another app is frontmost, with A visible, covered by B, parked beyond the displays, on another desktop or minimized. Each trial is judged from the fixture's own log: an effect in B, or an event delivered to B, is a wrong-window failure. `Scripts/input-probe-apps.sh` repeats typing and scrolling on TextEdit (two temp documents) and Safari (two local pages), judged from each window's Accessibility state. Reports: [fixture](input-probe/2026-09-29-fixture.md), [apps](input-probe/2026-09-29-apps.md).

| Route | Typing | Click | Scroll | Menu shortcut |
|---|---|---|---|---|
| Accessibility actions on A's elements (public) | **Pass in every condition** incl. parked, other desktop, minimized; TextEdit too | **Pass everywhere** (AXPress) | **Pass everywhere** (scroll bar value); TextEdit, Safari too | **Wrong window**: menu items act on the key window |
| `postToPid` (public) | **Wrong window**: keys go to the app's key window (fixture, TextEdit) | No effect (no window) | No effect | **Wrong window** |
| `postToPid` naming A (event fields 51/91/92 + private `CGEventSetWindowLocation`) | **Wrong window**: keys still go to the key window | **Pass** except minimized; makes A key within its app | **Pass** except minimized; TextEdit, Safari too | **Wrong window** |
| Activate app, raise A, post, hand focus back (public) | Pass on screen | Pass when the point is on a display (not parked) | Same | Pass |

Conclusions so far, on one fixture and two apps:

- **No route delivers keyboard events to a non-key window.** Keys always follow the app's key window, so exact-window typing needs either Accessibility text insertion (committed text only; no IME composition, no key bindings) or making A key first, which changes the app's own focus.
- **Pointer events can target the exact window without activation** through the window-targeted event, including parked and other-desktop windows, but it relies on undocumented event fields and a private SPI. It is gated by policy in the model below.
- **Accessibility semantic actions are the reliable public baseline** for button presses, text insertion and scrolling while the source is out of sight, and they need no pointer or focus change. Their reach depends on each app's Accessibility tree.
- **Menu shortcuts are app-scoped to the key window by design.** Sending one for a non-key window is refused.
- The activate route works on screen but moves the pointer, switches the frontmost app and, for other-desktop windows, switches desktops, so it conflicts with parking.
- Safari typing was inconclusive: neither AX insertion nor key events changed the page's `textarea` as read through Accessibility. Notion was not probed: only one window was open, and the probe does not create windows in a personal workspace.
- Setting focus on an element of a window on another desktop switched the active desktop once. That side effect needs a follow-up before AX focus is used for off-desktop sources.
- Incident: an early harness revision posted a Command-flagged key to the system event tap without a matching Command key-up, which left Command logically held for the session until it was released. The harness now sets explicit flags on every event, sends modifier up events and verifies that no modifier is held after each trial.

`DropyCore/InputCapability.swift` (issue #10) turns trials like these into decisions: a route is verified for an input kind and source condition only when it passed with another window key *and* with the app inactive; any wrong-window trial disqualifies it. `InputPlanner` refuses to send when the target is ambiguous, unreachable or changed, prefers exact-element Accessibility actions, uses the private window-targeted route or focus-changing routes only when the policy allows them, and labels a source view-only unless some kinds are verified.

Not yet covered: IME, dead keys, context menus, sheets and file dialogs, drag and drop, hover, momentum scrolling, Electron/Chromium, and wiring input into Dropy's preview.

## Platform facts and open questions

Apple documents desktop-independent window capture and its behavior when a window is occluded, off-screen or minimized. The stream can deliver GPU-backed frames, but it does not give Dropy ownership of another app's views or native event loop. Apple documents `CGEvent.postToPid` as process-targeted, and Accessibility actions as requests on exposed UI elements. Research has not found a documented public API for sending a complete native event stream to the exact foreign window represented by an `SCWindow` while that window is mirrored inside Dropy. This is an unresolved engineering question, not a claim of impossibility. [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [advanced capture session](https://developer.apple.com/videos/play/wwdc2022/10155/), [CGEvent posting](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)), [Accessibility actions](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction).

Menus, sheets, IME candidate windows and drag/drop may use surfaces and system interactions outside a selected main-window image. Apple's stream configuration exposes `includeChildWindows`, but the exact behavior needs tests for the chosen filter and each target workflow. [ScreenCaptureKit child windows](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/includechildwindows), [AppKit dragging sessions](https://developer.apple.com/documentation/appkit/nsdraggingsession).

Dropy therefore separates capture/presentation from input/focus and source placement. The [roadmap](../ROADMAP.md) defines the experiments and exit conditions before a broader compatibility claim.

Review hardening for Space recovery: automatic retries target records loaded at launch or windows whose restoration was explicitly requested; they do not undo new active placements. Failed window-server queries and failed AX reads defer rather than proving closure. A restore is journaled as unconfirmed before it changes the source, so an interrupted partial restore remains pending instead of being discarded as a later user move.
