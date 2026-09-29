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

## Now: M3 compatibility and reliability gates

Status after the 2026-09-29 session (details and raw reports in the [compatibility matrix](docs/COMPATIBILITY.md)). New keyboard features (shortcuts, editing keys, IME) stay deferred until these gates pass; parking stays experimental.

| Gate | Pass condition | Status |
|---|---|---|
| Electron input | Disposable two-window Electron app: clicks, scrolling, typing with the target visible, covered, parked, minimized, on another desktop; decoy untouched; pointer, focus, desktop, modifier and button state measured | **Partly passed.** Click (Accessibility press, pressable elements only) verified in all five conditions; scroll verified visible, covered and parked; no effect on another desktop or minimized. Typing has **no verified route** and is refused. No trial moved the pointer or left a modifier or button held |
| Routing regressions | Source resize, rapid switching, quit/relaunch and stale text targets refuse input whenever identity or geometry is uncertain | **Passed** on the AppKit fixture (device) and in unit tests (`PreviewInputGate`) |
| Recovery | Placement restoration, "your move wins" and crash recovery for TextEdit and the Electron fixture | **Passed** for both: all four placement modes restored, a move during placement kept, a journal restored after `kill -9` ([TextEdit](docs/device-checks/2026-09-29-recovery-textedit.md), [Electron](docs/device-checks/2026-09-29-recovery-electron.md)). Not run: recovery while on another desktop for these two apps (fixture-only, 2026-09-29) |
| Performance | One coordinated idle-Mac benchmark: closed, open idle, actively updating | **Run; two budgets fail.** Closed 0.0% CPU; active 10.8% CPU, 57 fps, +4 GPU points. An unchanged source costs 4.3% CPU (budget 2%) and presents fewer than half its frames. Background load was not idle ([benchmark](docs/BENCHMARK.md#coordinated-benchmark-2026-09-29)) |
| Real apps | The same matrix on third-party Electron, WebKit and media apps with disposable content | Open: needs apps whose windows and documents can be created and discarded without touching personal workspaces |

Next, in order: a Chromium typing route that targets the exact field without making the window key (or an honest "type only when the source is key" mode with visible focus handling); Safari page input; third-party apps with disposable profiles; then IME and editing keys.

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
