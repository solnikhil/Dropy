# Dropy roadmap

This is the working sequence for turning Dropy from a live window preview into a dependable notch container. The end goal is an existing app's UI inside a Dropy-owned overlay, with its session intact after dismissal. The current build is **view-only**, and the source window remains visible elsewhere. We will publish compatibility by tested workflow rather than imply universal support from an early demo.

Milestones are **evidence gates**, not calendar promises. Work may move between phases when an experiment changes the architecture. Each milestone has an explicit completion condition so a narrow success cannot be mistaken for the full product.

| Milestone | Deliverables | Exit condition |
|---|---|---|
| M0 · Project foundation | Public repository, MIT license, build/test CI, contribution and security guidance, product contract, issue backlog | A clean checkout builds on a supported macOS runner; project scope and limitations are visible to contributors |
| M1 · Capture and lifecycle | Exact window identity, capture metadata, latest-frame rendering, permission states, source-quit and stream-interruption recovery, diagnostics | Repeated open/select/switch/close cycles leave no stuck overlay, leaked capture, wrong-window preview or lost source app; measurements are reproducible |
| M2 · Containment feasibility | Compare occlusion, ordinary off-screen moves, hidden/minimized windows, other Spaces and isolated virtual-display research; track restoration | At least one maintainable method keeps a representative source app out of sight while its live UI and related surfaces remain usable, or the limitation is documented and the product contract is revised transparently |
| M3 · Interaction feasibility | Exact-window pointer/scroll/keyboard bridge, focus rules, accessibility fallback, IME and menus/dialogs/drag-drop matrix | A named cross-toolkit app set passes the written interaction and containment contract without acting on the wrong window; unsupported workflows remain clearly labelled |
| M4 · Product experience and performance | Direct/last/picker opening, app pinning, size and region controls, dismissal, shortcut and notchless entry, accessibility, multi-display/full-screen behavior, benchmark suite | End-to-end journeys pass on target hardware; latency and resource budgets are measured and met for supported workflows |
| M5 · Release candidate | Compatibility matrix, signed/notarized packaging, update and rollback policy, documentation, privacy review, regression testing | Reproducible release with honest app/workflow support and no unresolved data-loss, security or source-window restoration failure |

## Interaction decision (2026-10-07) and status (2026-10-08)

The M3 input bridge is replaced by using the real window (see [ARCHITECTURE](ARCHITECTURE.md#interaction-the-real-window-in-the-overlay-decision-2026-10-07) and the [interaction plan](docs/design/2026-10-07-interaction-engine-plan.md)). Built: docking (Native), the hidden Stage display for pinned apps, and Live mode over full-screen apps, each smoke-tested once on device with TextEdit and Safari. Open:

- **Manual testing by a person:** how the Live pointer hand-off feels, dragging from a Live window to another app, menus that extend past the window (the stream is clipped to the window's region), resizing or moving a window while Live.
- **Measurements:** extend `benchmark-phases.sh` with the Stage states (closed with a staged app, Native, Live) and make the plan's budgets release gates.
- **Not handled yet:** Stage Manager, several displays, more than one pinned app, a crash that leaves a staged window on desktop 1 (macOS rescues it there; the journal restores its frame but not its desktop).
- **Distribution:** `CGVirtualDisplay` is private; Dropy is Developer ID only (it cannot be sandboxed anyway).

## Animations (2026-10-09)

Built: the animation format and its limits, the Animation Studio (springs, keyframes, drawing the curve, content timing, undo, autosave), the gallery, share codes, playing on the notch, and the agent workflow (guide in the folder, a prompt in Settings, `Dropy animation` commands). See [docs/ANIMATIONS.md](docs/ANIMATIONS.md). Open:

- **Where the overlay opens from (built 2026-10-11, not yet tried on device):** Settings › Overlay › Open From offers the notch, the left and right edges and the bottom corners. An edge is the top-edge outline turned; a corner has its own outline (an ear on each edge, one rounded corner). Every animation plays at every position (`width` along the edge, `height` into the screen), and `Dropy animation play` uses the chosen position. Away from the notch the outline grows from a small nub and fades in. Open: a person trying each position with the window list, the preview, Native and Live; a showing Dock moves the edge it sits on to its inner side (macOS draws the Dock above every window, so it covered a docked app), which leaves the outline's ears against the Dock's top rather than the screen edge; "Hide the Dock" (shown when the position shares the Dock's edge) instead turns on the system's Dock auto-hide through System Events while Dropy runs and restores it when no longer needed or on quit, so the overlay keeps the real edge. A release build signed with the hardened runtime will need the Apple Events entitlement for it; the Studio's preview still shows the notch only; notch hover stays notch-only (and paused).
- **Manual testing by a person:** how editing feels in the Studio (keyframe dragging, the spring handle, the pen), and custom animations in daily use.
- **Measurements:** `bun run bench -- --animation <file>` measures a build with a custom animation; no budgets for custom animations yet beyond the limits in the format.

## Earlier: M3 compatibility and reliability gates

Status after the 2026-09-30 session, judged against the written [M3 workflow contract](docs/COMPATIBILITY.md#m3-workflow-contract). **M3 is not complete** (see the exit evaluation there). New keyboard features stay deferred; parking stays experimental.

| Gate | Pass condition | Status |
|---|---|---|
| Written contract | Support levels, conditions, pass/fail rules, containment and exit condition written before promotion | **Done** |
| AppKit | TextEdit meets containment and click/scroll/typing visible and parked | **Passed**, including parked recovery on another desktop |
| WebKit | Safari meets containment and click/scroll visible and parked | **Passed for page buttons and scroll**; containment passes but parked capture is throttled (≈5 fps). Typing and caret clicks **refused**: a value rewrite edited another element; keys reached window B on another desktop. Other desktop: app-inactive passed, window-B-key NOT RUN |
| Chromium/Electron (third party) | One real Electron app meets containment and click/scroll visible and parked | **Failed / blocked**: VS Code (scratch) caret clicks unreliable, no scroll route measured, keys reach window B; containment not run. Further VS Code runs are blocked: its updater is shared with the person's install whatever the profile. Next: a separate copy of the app outside /Applications with updates disabled at the app level, or another Electron app with no self-updater. The disposable fixture passes click/scroll but does not count |
| Media | One media player meets containment and click/scroll | **Failed for input**: QuickTime passes containment (parked capture throttled ≈10 fps) but exposes no playback controls to Accessibility; view-only |
| Unsupported workflows | Refused visibly, reaching neither window | **Passed** end to end at `ac1eab4` (28/28 rows): right-click, the second click of a double-click, drag, Option-scroll, Command-K, left arrow and delete each reached neither window and showed a refusal. Permission loss refuses every send (device regression passed). IME refusal not exercised on device. `EvidenceTool policy` (CI) fails if evidence would enable any refused workflow |
| Routing regressions | Resize, switching, relaunch, stale field, permission loss, app version refuse | **Passed** in unit tests and on device, including input to an updated and to an unversioned app (refused) |
| Latency (M4, measured only) | Idle input-to-visible traced before any change | Idle input-to-present p50 125–136 ms; the first two drawables after idle are never shown. No change made |

Remaining gates need a person's decision (details in [FEASIBILITY](docs/FEASIBILITY.md#remaining-m3-gates-isolation-assessment-2026-09-30-0800)): no installed Electron app can be isolated from the person's own copy (shared updater, dotfiles, accounts), and the only account-free media player exposes no controls. The isolation mechanism for such an app (disposable copy with its own identifiers, own HOME, before/after fingerprint of everything shared) is built and tested; running it needs a copy and the person's approval (9.6 GiB free on 2026-09-30 13:23; the copy helper requires 5 GB left after copying).

**Device checks are paused by the person's decision (2026-09-30 13:22).** No HID or device scripts, no capture launched from a terminal, no Screen Recording request, no switch to a development-signed build, and no third-party download, until the person explicitly changes this. Only local code review, unit tests, research and documentation continue. M3 stays incomplete; nothing measured on the device since 07:43 is claimed. Device runs from a terminal also re-raise a screen-capture prompt each time; a signed, LaunchServices-launched test build is the fix.

Barriers to M3, in order: (1) apps throttle a fully hidden window, so "out of sight" and "live" conflict for animating content; (2) no Chromium third-party app exposes clicks and scroll reliably enough through the tested routes (next: pressable workbench controls in VS Code judged by their own state, and window-targeted wheel events judged from the editor's visible range); (3) media apps expose no controls to Accessibility; (4) typing outside AppKit needs the hand-off design in FEASIBILITY, which gives up containment while typing.

## Now: M1 work order

1. Introduce stable source identity and event-driven re-resolution when a selected window closes, moves or changes size. Never trust an old numeric window ID after a target relaunch.
2. Add structured capture diagnostics: stream start, first complete frame, output dimensions and pixel format, stale/dropped frames, stop and error reasons. Avoid logging window titles or captured content by default.
3. Model permission denied/revoked and target quit as distinct states. A failure must leave the source app available through normal macOS controls.
4. Establish a repeatable visual and resource benchmark on one native app, one browser/Electron app and one media app. Set budgets from the baseline instead of guessing numbers.

## Feasibility experiments that decide M2 and M3

For every test, record macOS build, target app/version, captured `SCWindow.windowID`, target PID, active app/key window, screen and scale, source visibility, event recipient, and whether secondary UI escapes the container. Compare:

- A and B windows in one app, with each focused in turn; click B while capturing A to catch wrong-window routing.
- Left/right click, hover, wheel/momentum, selection, typing, shortcuts, dead keys, IME composition/candidate panel, context menus, sheets, file dialog, internal drag and cross-app drag/drop.
- Native AppKit, WebKit/browser, Electron/Chromium, and music-app windows. One successful Accessibility button press is a useful control, not a pass for these workflows.
- Covered, normally moved off-screen, specially unconstrained test window, hidden, minimized, another Space, full-screen, Stage Manager and mixed-DPI/multi-display source placement.

The [feasibility record](docs/FEASIBILITY.md) explains why these gates exist. A private virtual-display path is isolated research until it passes maintenance, pointer-routing and recovery tests; it is not a hidden dependency of the public-API foundation.

## Product decisions

- Keep the overlay owned by Dropy and expanded **in place** from the notch, temporarily covering menu-bar items beneath it.
- Keep direct-open, last-used and picker flows distinct. App pinning, selected-region display and automatic dismissal are planned work, not current features.
- Publish support as **view-only**, **interactive for named workflows**, or **unsupported**, with a dated app/OS/version matrix.
- Use platform-specific backends. Windows may share the product contract and tests, but its capture/input/windowing architecture is a later track.

## How to contribute

Choose an issue in the current milestone or propose a focused experiment. Include a reproduction, expected/observed result and the environment. For implementation PRs, keep capture, input, source placement and UI boundaries explicit, and update the compatibility record when behavior changes. See [CONTRIBUTING.md](CONTRIBUTING.md).
