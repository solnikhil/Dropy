# Interaction engine: research and plan

Research and plan, 7 October 2026. Nothing here is built yet. It builds on what ships on `notch-app-shell`: docking the real window, which puts the window back where it was on close, plus the view-only preview. The local measurements cited come from `docs/BENCHMARK.md` and `docs/FEASIBILITY.md`.

## 1. The answer in short

**No method lets someone use an app normally while its window stays wherever it happens to be.** On macOS:

- the keyboard always goes to the front app's focused window;
- menus, popovers and input-method windows open next to the real window, on its own display and desktop;
- a window on another desktop or fully covered is treated as hidden, and apps slow its drawing;
- there is no public way to move another app's window to a different desktop, and the private way fails on current macOS.

A cast-and-forward bridge therefore stays broken however well it is built. Section 3 has the evidence.

**What is achievable** is to give the window a place that is always "on screen" for macOS, is never seen by the person, and can be reached from every desktop. That place is a **hidden virtual display owned by Dropy, called the Stage**. A window can move between displays with public Accessibility calls, and it always lands on the destination display's current desktop. So the Stage makes a pinned app reachable from any desktop, and even over full-screen apps.

On top of the Stage, Dropy uses the app in one of two ways and picks automatically:

| Mode | How it works | Feels like | Used when |
|---|---|---|---|
| **Native** (what ships today, improved) | The real window moves from the Stage into the notch on the current desktop, and its app comes to the front | Exactly native: no added latency, nothing forwarded | Default, on any ordinary desktop |
| **Live** (Dropy's own interaction system) | The window stays on the Stage. Dropy streams it into the notch. The pointer is handed over to the Stage and Dropy draws its own cursor. The keyboard goes to the app natively, because it is the front app | Native behavior, plus about two to three screen refreshes of picture delay | A full-screen app is in front, or the window cannot come to the current desktop |
| **Preview** (exists) | View-only stream | — | No Accessibility permission, or the person chose it |

What the person gets:

- **Pinned apps open on any desktop and over full-screen apps.** They open instantly, because the window is already rendered and sized.
- **The app is never hidden, and its other windows are never touched.**
- **Native speed in the common case.**

The cost is one private API (`CGVirtualDisplay`, which BetterDisplay, DeskPad and others use), plus engineering for the pointer hand-off in Live mode. Every step starts with a measured spike that has a go/no-go rule. If the Stage fails, Dropy keeps today's behavior and adds the follow-the-window fallback.

## 2. What "use the app normally" requires

| Need | Native | Live | Old cast-and-forward bridge |
|---|---|---|---|
| Typing, shortcuts, dead keys, input methods, secure fields | Yes | Yes (app is in front) | Only AppKit text, and only into the focused window |
| Menus, context menus, popovers, sheets, open/save panels | Yes | Yes: they open on the Stage, inside the streamed area (§5.5) | No: they open beside the hidden window |
| Hover, cursor shapes, tooltips | Yes | Yes, with Dropy's own cursor (cursor image is spike S4) | No |
| Drag and drop, within the app and to other apps | Yes | Within the app yes; to other apps is spike S4 | No |
| Scroll, momentum, trackpad gestures | Yes | Yes (real events) | Partial |
| VoiceOver and other Accessibility tools | Yes | Partial: focus is on the hidden display | No |
| Works from any desktop | With the Stage (§5) | Yes | Only if capture keeps up (it does not, §3) |
| Over another app's full-screen space | No: a normal window cannot join it | Yes | View only |
| Added picture delay | 0 | About 2–3 refreshes (§6) | 2–3 refreshes plus routing |
| Screen-recording indicator | Brief, during the open and close animation only | While open | While open |

## 3. Facts that constrain every design

Each fact is either measured on this project's test Mac or sourced.

1. **The keyboard follows the front app's focused window.** Keys posted to a process or "window-targeted" go to the app's key window. They reached the other window in every probe trial where that window was key (FEASIBILITY, "Exact-window input"). Background posting works only when the target happens to be the key window ([MacKeyRelay](https://github.com/chasonyu/MacKeyRelay); [Apple forums 724835](https://developer.apple.com/forums/thread/724835)).
2. **Secondary UI opens where the real window is:** menus, context menus, popovers, sheets, input-method candidates and autocomplete lists. A window on another desktop shows them on that desktop, outside any cast. AppKit menus also track the *real* pointer, so menus cannot be driven by events posted to a window.
3. **Hidden windows are slowed down.** AppKit counts a window as occluded when it is fully covered by an opaque window, ordered off screen, minimized, or on another desktop ([AppKit 10.9 release notes](https://gist.github.com/zwaldowski/8710fddc8b0b39d2c152)). WebKit stops rendering such windows. Measured here: parked Safari fell to about 5 fps and QuickTime to about 10 (FEASIBILITY, "Containment throttling"). **A window on a display that exists and is not covered is visible to AppKit.** That is the property the Stage relies on.
4. **Desktops cannot be crossed without help.** No public API moves another app's window to another desktop. The private "compat ID" path reports success but does nothing on recent macOS ([Hammerspoon #3897](https://github.com/Hammerspoon/hammerspoon/issues/3897)). yabai needs code injected into the Dock with SIP turned off ([yabai wiki](https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection)).
5. **Displays can be crossed.** Accessibility moves windows between displays; Rectangle's "Next Display" and similar tools do this ([Rectangle #1863](https://github.com/rxhanson/Rectangle/pull/1863); [go-macos/accessibility](https://github.com/go-macos/accessibility)). A window moved to another display lands on *that display's current desktop* ([yabai #477](https://github.com/koekeishiya/yabai/issues/477)). With "Displays have separate Spaces" on, which is the default, each display switches desktops on its own ([MacMost](https://macmost.com/macs-with-two-displays-choose-windows-across-displays-or-separate-spaces.html)).
6. **Cross-process embedding needs the other process to cooperate.** `CALayerHost` can show another process's layer tree live, but only when that process publishes its context ([TeamDev](https://teamdev.com/jxbrowser/blog/cross-process-rendering-using-calayer/); [outerframe](https://probablymarcus.com/blocks/2026/05/10/like-a-web-view-but-native.html)). Third-party apps do not.
7. **Capture cost and delay, measured here** (BENCHMARK, M2 Air, 60 Hz):
   - capture to callback: under 1 ms;
   - frame age: p50 25–43 ms and p95 34–50 ms, because composing a windowed app takes about two refreshes;
   - CPU: 10.8% at 60 fps and about 2% for a still source;
   - GPU: +1.8 to +4 points;
   - idle input to visible: 125–135 ms, caused by the 10 fps idle rate and dropped drawables after idle.

   A stream left running is very expensive: one report measured 50–60% WindowServer GPU for a forgotten stream ([openai/codex #35659](https://github.com/openai/codex/issues/35659)).
8. **Screen capture is visible to the person.** A purple indicator shows in the menu bar while any app captures, and it cannot be hidden ([Bartender note](https://www.macbartender.com/Bartender5/ScreenCaptureMenuBarItem/); [Apple](https://support.apple.com/en-gb/118449)). Since Sequoia, macOS also re-asks monthly ("…requesting to bypass the system private window picker…") ([Michael Tsai](https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/); [9to5Mac](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/)). This was seen on this Mac on 2026-09-30.
9. **The App Store is already out.** Sandboxed apps cannot post events or control other apps through Accessibility ([Apple forums 94640](https://developer.apple.com/forums/thread/94640); [Quicopy](https://www.quicopy.com/blog/macos-sandbox-keyboard-shortcuts)). Dropy ships with Developer ID either way, so a private API costs Dropy less than usual.
10. **The cursor image is shaky.** `NSCursor.currentSystem` returns the current cursor whichever app set it ([codejam](https://www.codejam.info/2024/02/current-system-cursor-swift.html)), but it is deprecated since macOS 15 ([Apple forums 760305](https://developer.apple.com/forums/thread/760305)), and capturing the cursor regressed on Tahoe ([Apple forums 819931](https://developer.apple.com/forums/thread/819931)).
11. **Virtual displays work on current macOS.**
    - BetterDisplay 5 supports macOS 26 and 27 ([releases](https://github.com/waydabber/BetterDisplay/releases)).
    - The API is a descriptor (size, identity, termination handler) plus settings (HiDPI, modes) plus a mode (pixels, refresh rate).
    - A display lives while its object is retained and disappears when the process exits.
    - Known issues: changing modes in code is ignored or makes the display impossible to remove, removal takes 250–1900 ms, and macOS remembers the arrangement per identity ([go-macos/virtualdisplay](https://pkg.go.dev/github.com/go-macos/virtualdisplay); [vdisplay](https://github.com/pacifistazero/vdisplay)).
    - Adding a display may rearrange windows ([BetterDisplay discussion #4003](https://github.com/waydabber/BetterDisplay/discussions/4003)).
12. **Prior art for pointer hand-off.**
    - DeskPad brings its window forward and "teleports" the cursor when the pointer reaches its virtual display ([DeskPad](https://github.com/Stengo/DeskPad)).
    - BetterDisplay's interactive picture-in-picture moves the real pointer to the source screen ([BetterDisplay PiP](https://betterdisplay.pro/guide/interface-reference/app-menu/device-menu/picture-in-picture/)).
    - Deskflow shows the pitfalls: the cursor jumps on the first move, a hidden cursor comes back, and leaving from a secondary display behaves differently ([#9779](https://github.com/deskflow/deskflow/issues/9779), [#10184](https://github.com/deskflow/deskflow/pull/10184), [#10225](https://github.com/deskflow/deskflow/issues/10225)).
    - Warping the cursor ignores hardware motion for 0.25 s unless the suppression interval is set to 0 or the mouse is re-associated with the cursor right away ([Colin Cornaby](https://www.colincornaby.me/2023/02/mac-games-and-cursor-warping-weirdness/)).

## 4. Options evaluated

| | Option | Typing and menus | Delay | Any desktop | Over full screen | Private API or SIP | Verdict |
|---|---|---|---|---|---|---|---|
| A | **Native dock** (ships today) | Native | 0 | No: the window must be on the current desktop | No | None | Keep, as the Native mode |
| B | Cast plus forwarded input, window left where it is | Broken (facts 1–3) | 2–3 refreshes plus routing | No: frames stop | View only | Private event fields | Rejected, measured in M3 |
| C | **Stage live cast** with Dropy's pointer hand-off | Native (app in front, real pointer on the Stage) | +2–3 refreshes | Yes | Yes | `CGVirtualDisplay` | **Adopt as Live mode** |
| D | **Stage as home + Native dock** | Native | 0 | Yes: Stage to current desktop is a display move | No (use C) | `CGVirtualDisplay` | **Adopt as the default path** |
| E | Follow the window: activate, then macOS slides desktops | Native | 0 plus a desktop slide each way | Yes, visibly | No | None | Fallback when there is no Stage |
| F | Private desktop moves, or Dock injection | Native | 0 | Yes | Partly | Broken, or needs SIP off | Rejected (fact 4) |
| G | `CALayerHost` / remote layers | — | 0 | — | — | Needs the app's cooperation | Rejected (fact 6) |
| H | Accessibility "semantic" layer: press buttons and set values without focus | Commands only | Small | Yes | Yes | None | Later, as quick actions; not a primary interaction |
| I | Web-app mode: Dropy hosts the service's website itself (ChatGPT, Notion, Todoist) | Native web | 0 | Yes | Yes | None | Separate content type; complements, does not replace |
| J | App-specific integrations: Now Playing via [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), Shortcuts / App Intents | Purpose-built | 0 | Yes | Yes | Workaround for MediaRemote | Later, as widgets for media and quick actions |
| K | Virtual HID or DriverKit input device | Same routing limits as B | — | — | — | Driver install | Rejected: injection was never the problem |

C and D share almost everything, the Stage above all, so they form one design with two modes.

## 5. Recommended architecture

### 5.1 Concepts

- **Stage**: one virtual display owned by Dropy for the lifetime of the process. It is HiDPI at the notch display's scale and refresh rate, sized to the largest overlay. It sits at a corner of the display arrangement, has a stable identity ("Dropy Stage") so macOS remembers where it is, and is guarded so the pointer only enters through Dropy.
- **Curtain**: an opaque Dropy window that covers the Stage while nothing on it is in use. Windows under it count as covered (fact 3), so apps idle there and save energy.
- **Pinned window**: lives on the Stage between openings. When unpinned, or when Dropy quits, it goes back to where the person had it, using the journal.
- **Borrowed window**: chosen from the picker. It docks, then returns to its original place on close, as it does today. Live mode may stage it for the duration of one session.
- **Session**: one opening. It runs in exactly one mode (Native, Live or Preview) and may switch, for example when the person enters full screen.

### 5.2 How the mode is chosen (pure logic in DropyCore, unit-tested)

| Condition | Mode |
|---|---|
| No Accessibility permission | Preview |
| The notch display's current desktop is a full-screen app | Live |
| Stage unavailable (API missing, creation failed, "Displays have separate Spaces" off) | Native from the original position, with follow-the-window for other desktops. Over full screen: Preview |
| Window cannot be resized to the target | Native at its own size, or Live with the stream scaled if it is too big |
| Stage Manager on | Decided by spike S5 |
| Otherwise | Native |

### 5.3 Components

**New in DropyCore** (no AppKit, unit-tested):
- `SessionModePolicy`: the table above.
- `StageGeometry`:
  - Stage size from the size presets, the menu bar and a safety margin;
  - window slots;
  - where to place the Stage in the arrangement (a corner, so few screen edges touch it);
  - the mapping between the notch hole and the Stage, both ways;
  - boundary rectangles with hysteresis.
- `PointerHandoff`: a state machine (outside → entering → inside → dragging → leaving). Inputs are pointer locations, motion and buttons. Outputs are warp commands and software-cursor positions. Pure, so every edge case can be tested: entering mid-drag, leaving while a menu is open, pushing against a display edge.
- Journal: a new `PlacementMode.staged` so quit and crash recovery know about windows on the Stage.

**New in Dropy (AppKit):**
- `StageDisplay`:
  - creates the virtual display through the Objective-C runtime (`NSClassFromString` plus key-value setters), so no private headers are needed;
  - places it with `CGConfigureDisplayOrigin`;
  - checks availability at launch;
  - watches its termination handler and display reconfiguration.
- `StageCurtain`.
- `StageBarrier`: an event tap that keeps the pointer from wandering onto the Stage. It extends `NotchCursorRestriction` and its proven "re-enable after timeout" handling. The tap runs on its own high-priority thread.
- `LiveCaster`:
  - a ScreenCaptureKit stream of the Stage region, so menus and popovers on the Stage are included (§5.5);
  - frames are shown by setting the frame's surface directly as a layer's contents, measured against the current Metal path (§6);
  - runs at full rate while the person interacts and at an idle rate otherwise;
  - the stream lives exactly as long as the session (fact 7).
- `PointerHandoffController`: drives `PointerHandoff` from the tap. It warps the cursor with `CGWarpMouseCursorPosition`, then re-associates the mouse (`CGAssociateMouseAndMouseCursorPosition(true)`) or uses a suppression interval of 0. It also draws Dropy's cursor in the overlay.
- `CursorMirror`: provides the cursor image, from `NSCursor.currentSystem` while it works, otherwise from the standard set or cursor capture (spike S4).

**Changed:**
- `WindowDock`: gains `moveToStage(slot:)` and `moveFromStage(to:)`, with the same journal discipline as today.
- `OverlayController`: becomes a coordinator that starts a `NativeSession`, `LiveSession` or `PreviewSession`. This also splits a ~1,200-line file so it can grow.

**Fixed along the way:** today, switching desktops while an app is docked leaves the overlay with an empty hole. The overlay must close on `activeSpaceDidChange` while a window is docked. It must not close for the window list or preview, because opening Dropy can itself switch desktops when its Settings window is on another one.

### 5.4 Flows

**Pin an app.**
1. Find the app's window, or launch the app without bringing it forward and wait for a window.
2. Record the window's original frame in the journal.
3. Move it to a Stage slot at the target size, then drop the curtain over it.

If the window is on another desktop, move it to the Stage directly if spike S2 shows that works; otherwise follow the window once.

**Open, Native.**
1. Start the morph. Its content is a live frame of the window, taken from the Stage before the window moves, never a stale snapshot.
2. Once the outline covers its place, move the window from the Stage into the hole. It lands on the current desktop of the notch display (fact 5).
3. Bring the app to the front and reveal the window.

**Close, Native.**
1. Cover the window with a fresh frame.
2. Move the window back to its Stage slot.
3. Collapse the outline.
4. Give focus back to the previous app if the person was still in the docked one.

**Open, Live.**
1. Lift the curtain over that slot and start the region stream.
2. Morph the outline open.
3. Bring the app to the front, so the keyboard goes to it.
4. Arm the pointer hand-off.

**While Live.**
- **Entering the cast:** when the pointer crosses into the cast, it moves to the matching point on the Stage. Dropy hides nothing on the real screens, because the real pointer is now on the Stage, and draws its own cursor where the real one would be.
- **Moving inside:** native events go straight to the app, so hover, cursor shapes, menus and dragging behave as usual.
- **Leaving:** when the pointer crosses the window edge, or pushes against the Stage's edge, it moves back to the matching point just outside the overlay.

**Close, Live.**
1. Stop the stream; it has no life beyond the session.
2. Drop the curtain.
3. Give focus back.

**Switching pinned apps inside the notch:** all pinned windows sit in Stage slots, so switching only changes which slot is uncovered and streamed, or which window docks. Nothing launches and nothing moves on the person's desktops.

**Quit:** move every staged window back to its original frame, then release the Stage.

**Crash:** the Stage disappears with the process and macOS moves its windows onto a real display. Spike S1 verifies this. The journal restores their frames at the next launch, as it does for docked windows today.

**Sleep, wake, display changes, Screen Recording or Accessibility revoked:** the Stage stays while the process runs. Every session re-checks the Stage, the window's identity and permissions. A failure falls back along §5.2 and says why.

### 5.5 Popups and the Stage's size

The Stage includes room above the window for its own menu bar (every display has one when "separate Spaces" is on) and a margin below it. The pointer is moved out before it reaches either, so the Stage's menu bar and Dock never show.

macOS keeps menus and popovers inside their display, which keeps them inside or close to the window's region. The streamed region is the window plus any popup windows the app owns that hang outside it. Those come from the window list, filtered by the app's process, so the overlay can grow briefly to show them.

## 6. Performance design and budgets

**Techniques:**
- No capture while closed. Streams are tied to the session (lesson from fact 7). Pinned windows stay behind the curtain, so they idle (fact 3).
- Native mode keeps the reveal as today: a covered swap, then no stream at all.
- Live mode captures only on change. It reuses the existing adaptive rate and identical-frame skipping, but holds full rate while there is pointer or key activity, which removes the 10 fps idle wait from the input path (fact 7).
- Presentation: test showing the frame's surface directly as layer contents (no render pass) against the current Metal path, and pace frames with `CAMetalDisplayLink`. Fix the drawables that are dropped after idle (BENCHMARK, idle trace). Keep the panel without a shadow, which was measured as the largest GPU cost (BENCHMARK).
- Pointer: the tap runs on its own thread and does no allocation per event. Dropy's cursor is a layer moved with animations off. Warps happen only at crossings, which avoids the "shake to locate" enlargement ([Apple forums 793236](https://developer.apple.com/forums/thread/793236)).
- The Stage is sized to the largest overlay, not to the full screen, to limit WindowServer memory and composition cost.

**Budgets.** The existing ones from BENCHMARK carry over. These are the targets that will act as gates:

| State | Target |
|---|---|
| Closed, with pinned apps on the Stage | Dropy CPU ≈ 0%, wakeups ≤ 1/s, no stream; staged apps throttled (measured with `powermetrics`) |
| Native open | Same as today after the reveal: no stream, Dropy CPU ≈ 0% |
| Live, still window | Dropy CPU ≤ 2%, added GPU ≤ 3 points |
| Live, 60 fps content | Dropy CPU ≤ 12%, added GPU ≤ 6 points |
| Live picture delay | Frame age p95 ≤ 50 ms at 60 Hz, ≤ 30 ms at 120 Hz |
| Live input to visible | p95 ≤ native + 50 ms at 60 Hz, down from 125–135 ms idle today |
| Live cursor | No more than one refresh behind where the hardware cursor would be |
| Open (Native or Live) | Warm p95 ≤ 300 ms to content, cold ≤ 600 ms |

## 7. Risks and mitigations

| Risk | Mitigation |
|---|---|
| A macOS update breaks `CGVirtualDisplay` | Probe at launch. Fall back automatically to Native from the original position, plus follow-the-window. Use the smallest possible slice of the API. BetterDisplay's support for 26 and 27 is a positive signal, not a guarantee |
| Creating the Stage rearranges windows or flickers | Create it once per login session, at Dropy's launch, with a stable identity. Spike S1 measures this. Never re-create it per opening |
| The pointer wanders onto the Stage | Corner placement plus `StageBarrier`. If the tap fails, it fails open and re-arms |
| The Stage shows in Displays settings and Mission Control | Name it clearly and explain it in onboarding. Mission Control shows the Stage's desktop like any display |
| An app refuses to move, resize or leave its desktop | Read back every move (as today). Fall back to Native-from-original or Preview, and say why |
| Bringing the app forward switches the person's desktop | Spike S5. Bring it forward only after the window is on the Stage or the current desktop |
| Dropy's cursor feels floaty | Spike S4 measures it. Alternatives: a hybrid where events are posted to the window while the hardware cursor stays visible, switching to the hand-off only while a menu or drag is open |
| The cursor image is unavailable on future macOS | Fall back to identifying the standard cursors, then to the captured cursor |
| Purple indicator and monthly prompt | Only during Live, plus brief snapshots. Explain once. The remote-access capture entitlement is not available to Dropy (fact 8) |
| Energy spent by staged apps | Curtain while closed. Spike S6 measures it |
| "Displays have separate Spaces" is off | Detect `com.apple.spaces spans-displays` and use the no-Stage path |
| Stage Manager or multiple displays | Spike S5. Ship with Stage Manager unsupported or limited if needed |

## 8. Execution plan

Every phase ends with tests and an exit check. Spikes are throwaway tools under `Scripts/bench/`, never app code. They run only with the person's go-ahead, because they add a display and move windows.

**Phase 0: spikes and go/no-go**

| Spike | Question | Pass |
|---|---|---|
| S1 Stage | Create a HiDPI Stage at the notch display's scale and refresh rate, place it at a corner, keep it 10 minutes, release it; kill the process with windows on it | Created in ≤ 1 s; no window on real displays moves; text is crisp at 2×; after a kill, the windows reappear on a real display |
| S2 Moves | Move windows from TextEdit, Safari, an Electron app, Finder and Notes: Stage to notch to Stage; from an inactive desktop to the Stage; while minimized or hidden; onto a display showing a full-screen app | Every move confirmed by readback in ≤ 100 ms and lands on the destination's current desktop; the result is known for inactive desktops and full screen |
| S3 Live cast | Stream a Stage region into a panel; measure frame age, CPU and GPU, with menus and popovers on the Stage | Meets §6 Live budgets; menus show inside the stream |
| S4 Pointer | Hand-off at the cast edges; Dropy's cursor; `NSCursor.currentSystem` on macOS 27; menu tracking, scroll momentum, dragging out to Finder, the shake-to-locate check | No stuck or jumping pointer in 100 crossings; menus and drags work; cursor lag ≤ 1 refresh (filmed at high speed, or with event timestamps against presentation) |
| S5 Focus and space | Bring the staged app forward with a full-screen app or another desktop in front; Stage Manager on and off; keyboard, input methods, secure input, ⌘-Tab | The person's desktop never changes; keys reach only the app; behavior with Stage Manager is known |
| S6 Energy | A video and an animation on the Stage, with and without the curtain, for 10 minutes | The curtain brings the staged app to throttled levels; Dropy's closed cost stays ≈ 0 |

**Decision rule:**
- S1 and S2 pass: build the Stage.
- S3 and S4 also pass: build Live.
- S1 or S2 fails: ship follow-the-window and stop.
- S3 or S4 fails: use the Stage as a home only (Native from the Stage), with no Live, and Preview over full screen.

**Phase 1: engine refactor, no behavior change.** Split `OverlayController` into a coordinator and sessions. Add `SessionModePolicy`. Close on desktop change. Exit: all existing tests pass, plus new policy tests and one device run of today's flows.

**Phase 2: Stage foundation.** `StageDisplay`, `StageGeometry`, `StageBarrier`, `StageCurtain`, the `.staged` journal mode, and quit and crash recovery. Exit: the S1 checks, automated (`device-checks.sh` gains a Stage section).

**Phase 3: pinned apps on the Stage, Native from the Stage.** Pin and unpin; open and close through the Stage; the live-frame opening; switching between pinned apps. Exit: pinned apps open on every desktop with no desktop slide; the window's original frame comes back exactly on unpin and quit.

**Phase 4: Live mode.** `LiveCaster`, `PointerHandoffController`, `CursorMirror`, used automatically over full-screen apps. Exit: §6 Live budgets met; the S4 and S5 checks pass on device.

**Phase 5: policy and product.**
- Stage Manager and multi-display rules.
- A pinned-app switcher in the notch.
- Settings: a choice of Automatic (Native + Live), Native only, or Preview.
- Onboarding copy for the indicator and the monthly prompt.
- Diagnostics in the support summary.

Exit: copy reviewed, settings searchable, support summary updated.

**Phase 6: measure and harden.**
- Extend `benchmark-phases.sh` with the Stage states: closed, Native and Live.
- Run five repetitions per workload on an idle system and on a second Mac model.
- Make the §6 budgets release gates.

**Later, separate tracks:** web-app mode (option I), and media and quick-action widgets (options H and J).

## 9. Decisions needed

1. **Where pinned windows live between openings.** Recommended: on the Stage, which is what makes every desktop and full screen work. The alternative is their original spot, as now, which keeps the other-desktop limit. Borrowed windows return to their original spot either way.
2. **Accept `CGVirtualDisplay`,** with automatic fallback. Recommended: yes. Dropy cannot be sandboxed anyway (fact 9).
3. **Live mode only when needed** (full screen), or also as a setting for people who never want windows moved. Recommended: automatic first, the setting later.
