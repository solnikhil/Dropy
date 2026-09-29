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
- **Accessibility semantic actions are the reliable public baseline** for button presses, text insertion and scrolling while the source is out of sight, without moving the pointer. AX text insertion sets the element focused; one off-desktop trial switched desktops, so focus changes must be treated as observed side effects rather than assumed absent. Their reach depends on each app's Accessibility tree.
- **Menu shortcuts are app-scoped to the key window by design.** Sending one for a non-key window is refused.
- The activate route works on screen but moves the pointer, switches the frontmost app and, for other-desktop windows, switches desktops, so it conflicts with parking.
- Safari typing was inconclusive: neither AX insertion nor key events changed the page's `textarea` as read through Accessibility. Notion was not probed: only one window was open, and the probe does not create windows in a personal workspace.
- Setting focus on an element of a window on another desktop switched the active desktop once. That side effect needs a follow-up before AX focus is used for off-desktop sources.
- Incident: an early harness revision posted a Command-flagged key to the system event tap without a matching Command key-up, which left Command logically held for the session until it was released. The harness now sets explicit flags on every event, sends modifier up events and verifies that no modifier is held after each trial.

`DropyCore/InputCapability.swift` (issue #10) turns trials like these into decisions: a route is verified for an input kind and source condition only when every recorded trial passed, including with another window key *and* with the app inactive; any wrong-window trial disqualifies it, and mixed pass/failure repeats stay unreliable. `InputPlanner` refuses to send when the target is ambiguous, unreachable or changed, prefers exact-element Accessibility actions, uses the private window-targeted route or routes with observed focus/desktop changes only when the policy allows them, and labels a source view-only unless some kinds are verified.

Not yet covered: IME, dead keys, context menus, sheets and file dialogs, drag and drop, hover, momentum scrolling and Electron/Chromium. For preview wiring, see the next section.

## Interactive preview prototype (M3, 2026-09-29, second session)

The preview can now send input to the source window, behind **Interactive preview (beta)** in the menu (off by default; it needs Accessibility). The owner accepted the private window-targeted route for pointer input. Every click, scroll or key goes through the same steps. The exact window is re-resolved and its window ID confirmed. `PreviewPointMapping` maps the point through the image actually drawn (fit, fill, native scale; letterbox areas send nothing). `InputPlanner` picks only routes verified for that app, input kind and source condition in the shipped `Resources/InputEvidence.json`. The label says what is verified ("Interactive (beta): click, scroll, type") and each refusal says why. An untested app, or another macOS major version, stays view-only.

Routes as shipped:

- **Clicks** through the window-targeted event when verified, else an Accessibility press, or, in text, the caret placed at the character under the point (`AXRangeForPosition`).
- **Scrolling** through the window-targeted event, else the scroll bar's value.
- **Typing** is committed characters only, inserted with `AXSelectedText` into the text element last clicked in that window. It is **not focused first**: focusing an element of an off-desktop window switched desktops, and insertion works without it (fixture, TextEdit). Shortcuts, editing keys (arrows, delete, return) and input methods are refused and labelled. Keyboard events are never sent: no route delivered them to a non-key window.

Evidence changes:

- Trials now record side effects by kind (source key window, frontmost app, desktop, pointer). The preview policy allows only "target became key inside its own app", which the window-targeted click causes. Anything that switches the person's app, desktop or pointer is refused.
- **The first harness run's setup was wrong for many trials**: cooperative activation on macOS 14+ refused `activate()` from a background process, so "B key" and "app inactive" were often not the real states. The probe now makes apps frontmost through Accessibility, uses a minimized fixture as the "other app" instead of Finder (which switched desktops), verifies the focus state before sending, and records setup failures as not run. The earlier 2026-09-29 tables remain as history; the evidence was regenerated only from records that carry side effects ([fixture](input-probe/2026-09-29b-fixture.md), [apps](input-probe/2026-09-29b-apps.md), [raw](input-probe/raw/2026-09-29b/)).
- **Safari (WebKit)**: `AXSelectedText` and the window-targeted click do nothing in a page `textarea` (only replacing `AXValue` changes it, which would overwrite the field), and caret placement had no effect either. So Safari is scroll-only. TextEdit: click (caret), typing and scrolling pass visible and parked. The window-targeted click did not move TextEdit's caret, so clicks there use Accessibility.

End-to-end through Dropy with real HID input on the preview ([report](device-checks/2026-09-29-interactive-preview.md)): on the input fixture, with window A visible and moved beyond the displays while window B is the fixture's key window, click, typing and scroll reached A and never B, and Dropy stayed frontmost. On TextEdit, a click on the preview placed A's caret and three typed characters appeared there, with B unchanged.

Dismissal with real HID events ([report](device-checks/2026-09-29-dismissal.md)): Esc, the global shortcut, click outside in another app, click on Dropy's own menu-bar item, and pointer-leave all passed, and focus returned to the previously frontmost app. Opening with the pointer elsewhere stayed open, and manual mode ignored outside clicks. The checks found and fixed two real bugs. The panel hid itself whenever Dropy deactivated (`hidesOnDeactivate`), so manual and pointer-leave overlays vanished on any outside click while Dropy still considered them open. Pointer-leave never fired, because the tracking-area owner's Swift methods were exported as `mouseEnteredWith:` and AppKit never called them.

TextEdit recovery rerun on one desktop ([report](device-checks/2026-09-29-textedit-recovery.md)): all four placement modes restored, a move during placement was kept (`keptUserChange`), and killing Dropy while parked left a journal that the next launch restored.

Not covered: Electron/Chromium input, IME, dead keys, editing keys, context menus, dialogs, drag and drop, hover, momentum scrolling, and multi-display previews.

## Compatibility and reliability gates (M3, 2026-09-29, third session)

**Electron/Chromium input.** `Scripts/input-probe.sh` with `TARGET=electron` drives a disposable two-window Electron 43.2.0 app (`Scripts/bench/ElectronFixture`: official release zip pinned by version and SHA-256, throwaway profile, local pages only, a small Node-API addon so the app can move its own window to another desktop, since WindowServer ignores that request from another process). It runs the same 192 trials as the AppKit fixture. Every trial now also records whether the pointer moved and whether a mouse button or modifier was left held; none were. Results ([report](input-probe/2026-09-29c-electron-fixture.md), [raw](input-probe/raw/2026-09-29c/)):

- Accessibility press passed in every condition, including other desktop and minimized, with no focus or desktop change, once `AXManualAccessibility` was set. Without it Chromium exposes only the title-bar buttons.
- Window-targeted scroll passed visible, covered and parked; no effect on another desktop or minimized.
- A window-targeted click on a non-key window only made it key; Chromium does not click through, so it is not a click route here.
- Typing: `AXSelectedText` did nothing in an `<input>`; key events followed the key window (wrong window). No typing route exists for a non-key Electron window.
- Dropy's hit test walked only the topmost child containing the point, and Chromium stacks empty full-size groups beside the web content, so the end-to-end click first failed with "nothing pressable". The hit test now backtracks to the branch holding an actionable element. End to end through the preview, click and scroll reached A only and typing was refused ([report](device-checks/2026-09-29-interactive-routing.md)).

**Routing when identity or geometry is uncertain.** A preview point used to be mapped with the selected window's last known size and whatever frame was on screen. Now each frame carries the stream geometry it was produced with (window ID, configured window size and output size), and `PreviewInputGate` refuses input when the handler belongs to an older selection, nothing is drawn, the frame came from another window, or the frame predates the current size. The router still compares the live window size. `Tests/DeviceInputRouterCheck.swift` adds real resize, rapid switching, replaced-field and quit/relaunch checks.

**Recovery on TextEdit and Electron** ([TextEdit](device-checks/2026-09-29-recovery-textedit.md), [Electron](device-checks/2026-09-29-recovery-electron.md)): all four placement modes restored exactly, a move made during a placement was kept, and a journal left by `kill -9` while parked was restored on the next launch, for both. Unlike WebKit, Chromium kept rendering while moved off-screen (354 frames shown in the hold), and AppKit's clamp left 2.4% of the smaller Electron window on screen, which parking covered completely. Recovery across desktops remains verified only on the placement fixture.

**Desktop ownership.** Every device script now takes one lock (`Scripts/lib/device-session.zsh`) and refuses to start while the keyboard or pointer was used in the last 5 s. This replaces `pgrep` matching, which also matched the launching shell's own command line. TextEdit and Safari are launched with `-ApplePersistenceIgnoreState YES`, so a check never restores, and then closes, a person's windows. Incident: one benchmark run that aborted on a script error left Dropy's saved preferences pointing at the Electron fixture. The next runs then saved and faithfully restored that wrong value. It was found at the end of the session and restored from the aborted run's own saved copy. The lock now keeps a copy of Dropy's preferences, and the next session restores it after any run that ends without cleanup, including `kill -9` (`Tests/LocalDeviceSessionCheck.zsh`). The idle check also no longer ends `ioreg` with SIGPIPE, which could abort a script under `pipefail`.

## Platform facts and open questions

Apple documents desktop-independent window capture and its behavior when a window is occluded, off-screen or minimized. The stream can deliver GPU-backed frames, but it does not give Dropy ownership of another app's views or native event loop. Apple documents `CGEvent.postToPid` as process-targeted, and Accessibility actions as requests on exposed UI elements. Research has not found a documented public API for sending a complete native event stream to the exact foreign window represented by an `SCWindow` while that window is mirrored inside Dropy. This is an unresolved engineering question, not a claim of impossibility. [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [advanced capture session](https://developer.apple.com/videos/play/wwdc2022/10155/), [CGEvent posting](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)), [Accessibility actions](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction).

Menus, sheets, IME candidate windows and drag/drop may use surfaces and system interactions outside a selected main-window image. Apple's stream configuration exposes `includeChildWindows`, but the exact behavior needs tests for the chosen filter and each target workflow. [ScreenCaptureKit child windows](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/includechildwindows), [AppKit dragging sessions](https://developer.apple.com/documentation/appkit/nsdraggingsession).

Dropy therefore separates capture/presentation from input/focus and source placement. The [roadmap](../ROADMAP.md) defines the experiments and exit conditions before a broader compatibility claim.

Review hardening for Space recovery: automatic retries target records loaded at launch or windows whose restoration was explicitly requested; they do not undo new active placements. Failed window-server queries and failed AX reads defer rather than proving closure. A restore is journaled as unconfirmed before it changes the source, so an interrupted partial restore remains pending instead of being discarded as a later user move.

### Review limitations (2026-09-29)

The checked-in input tables are historical observations, not a production capability registry. Their fixture and real-app rows were regenerated from the original JSONL and matched exactly; the [raw records](input-probe/raw/2026-09-29/) are now preserved alongside the reports. No route is wired into the preview. The review tightened repeat-trial verification, gated observed focus changes (including AX actions), checked fixture setup before sending, and made wrong-window observations override action errors. Future runs must record these side effects in `InputTrial.changesFocus`. The old reports predate setup validation and only describe this fixture/macOS/app combination; they do not prove universal support. Real-app probes observe AX state, not every received event, so an unchanged decoy cannot prove that no event was delivered there.

PR #27's follow-up review device run at `a76acee` completed all four placement modes for TextEdit, Safari and Notion and all three cross-Space fixture scenarios. TextEdit user-move precedence and ordinary crash recovery were skipped after a desktop change; dismissal, Screen Recording revocation and idle benchmark remain outstanding. Parking stays experimental.
