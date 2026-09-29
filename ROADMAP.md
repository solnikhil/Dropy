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

Status after the 2026-09-30 session (details and raw reports in the [compatibility matrix](docs/COMPATIBILITY.md)). New keyboard features (shortcuts, editing keys, IME) stay deferred; parking stays experimental.

| Gate | Pass condition | Status |
|---|---|---|
| Electron input | Disposable two-window Electron app: clicks, scrolling, typing with the target visible, covered, parked, minimized, on another desktop; decoy untouched; pointer, focus, desktop, modifier and button state measured | Click (pressable elements) **passed** in all five; scroll **passed** visible, covered, parked, no effect on another desktop or minimized. Typing **failed**: no route inserts at the caret of a non-key Chromium window (value rewrite lands at offset 0 and breaks undo; keys reach the decoy). Refused |
| Routing regressions | Source resize, rapid switching, quit/relaunch and stale text targets refuse input whenever identity or geometry is uncertain | **Passed** (device and unit tests). Clicks also refuse unless verified for the element class under the pointer |
| Recovery | Placement restoration, "your move wins" and crash recovery for TextEdit and the Electron fixture, including a source on another desktop | **Passed** for both, including TextEdit parked recovery on another desktop (normal and after `kill -9`), with the source and active desktops recorded independently |
| WebKit page input | Safari, local throwaway page: clicks and typing with the same checks | Button clicks **passed** visible, covered, parked, minimized (other desktop NOT RUN); caret clicks and typing **failed** (a value rewrite edited a different element). Enabled: button clicks only |
| Third-party Electron | One real Electron app with a scratch profile | VS Code 1.139.1: typing **failed** (keys reach the decoy), clicks **unreliable**, scroll **no route**. View-only |
| Performance (tracked here, owned by M4) | Idle input-to-visible latency traced before any pipeline change | **Traced, target not met.** Idle input-to-present p50 125–136 ms; frame age p95 81–107 ms against the provisional 50 ms. The first draw after idle misses twice (both pooled drawables) before the third is shown. Idle CPU 2.3% in one check (PR #30: 1.9%) |

Next, in order: find why the first two drawables after idle are never shown, and test one change against the trace (M4); a typing design that is honest about focus (for example typing only while the source window is key and visibly focused) or a caret-reporting API for non-key windows; Safari on another desktop through a desktop switch; a media app; then IME and editing keys.

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
