# Does Dropy improve a real workflow?

Performance and product demand are different questions. A fast synthetic window proves neither that a real app behaves correctly nor that someone benefits from keeping it at the notch. Use the benchmark suite to remove reliability/performance blockers, then run the following task study with a deliberately limited support claim.

## Candidate jobs

Test people who already switch to a small secondary app repeatedly while working:

1. **Quick reference:** consult a reference/note, use one fact in the primary task, dismiss and continue.
2. **Quick capture:** record a short thought or calculation and return to the primary task without losing context.
3. **Short conversation:** read a message, compose a response, then resume work. Use a disposable conversation for observation.
4. **Full-screen companion:** consult or edit the secondary app while the primary app stays full screen. This specifically exercises Live.

Start with five to eight consenting participants for qualitative discovery. This is a study-design choice, not a sample size that establishes statistical significance. Prefer people with the switching habit above; “any Mac user” is too broad to judge a niche tool.

## Counterbalanced comparison

Give each participant equivalent tasks with their current method (Command-Tab, a second desktop, side-by-side windows, or their own shortcut) and with Dropy. Alternate which method comes first and use different but comparable content to reduce practice effects. Allow a short learning period for both. Record:

- Completion time from the user's intent to the return to their primary task.
- Completed/failed task, wrong-window actions, lost text, misplaced windows or disrupted full-screen state.
- Extra actions, corrections and unexpected dismissals.
- Whether they preferred it, the concrete reason, and which task they would use it for again.
- Whether they voluntarily choose it during a subsequent week, and why they stop using it.

Use participant-selected scratch data and record task outcomes rather than personal screen contents. Keep raw observations, environment/app versions and failures; do not substitute “felt snappy” for measured completion or silently discard awkward trials.

Choose the decision rule before recruitment. A useful initial hypothesis is: Dropy reduces repeated secondary-app task time without increasing mistakes and participants voluntarily reuse it. Report within-person differences and concrete observations; do not infer broad demand from a small positive demo or synthetic benchmark. If results help only full-screen work or a single app class, narrow the product claim accordingly.

## Compatibility matrix to fill with real runs

Each row must record Dropy binary hash, macOS build, app version, display layout/scale/refresh rate and exact workflow. Empty rows are **not tested**.

| App class | Representative workflow | Required behaviors |
|---|---|---|
| Native AppKit | Scratch text editing/calculation | Caret/selection, key repeat, undo/redo, shortcuts, resize, exact restoration |
| Browser/WebKit | Reference page and text form | Scroll/zoom, links, text field, contextual menu, popup, restore |
| Electron/Chromium | Disposable editor/chat workspace | Multi-window identity, rapid typing, menus, IME, shortcuts, restore |
| Media | Account-free sample media | Controls, no playback disruption when Stage appears/disappears; protected-video behavior checked separately |

Across those rows, exercise normal desktop and full-screen workflows, menu/sheet/file dialog, multilingual IME and dead keys, drag within the app and across apps, minimized/hidden source, rapid switching, source quit/relaunch, permission denial/revocation, sleep/wake, screen lock, display detach/reconnect, mixed DPI, Stage Manager, Dock edges and non-notch displays. No combination inherits support from another one without evidence.

Prioritize **no lost work, no wrong-window input, no stranded window** before speed. Treat a fail in those categories as a release blocker. The fixture deliberately cannot certify actual text editing/IME/menu behavior; this matrix is the required complementary evidence.

## Interpretation

- Benchmarks pass, tasks fail: fix app compatibility or interaction design before distribution.
- Tasks succeed, benefit is unclear: refine the target job and repeat the comparison.
- Users benefit, reliability fails: fix reliability; demand does not excuse window/input failures.
- Both succeed on a defined matrix: run a limited external test with that support scope, a signed/notarized build, recovery instructions and a way to report failures.
