# Dropy

Dropy is a free, [MIT-licensed](LICENSE) macOS project building a temporary app container around the MacBook notch. The intended experience is to reveal an existing app's live UI in a Dropy-owned overlay, work there, and dismiss the overlay without losing the app's session.

**Current status: early native build, view-only by default.** Dropy can mirror a selected running window. An opt-in **Interactive preview (beta)** sends clicks, scrolling and typed text to the exact source window, but only for input verified on that app (currently TextEdit; clicks on page buttons and scrolling in Safari; clicks on buttons and scrolling in a disposable Electron test app). Typing works only in TextEdit: no tested route types safely into a Safari or Electron window that is not focused. A scratch-profile VS Code stays view-only. It does not yet hide the app's original window outside experiments. The [roadmap](ROADMAP.md) makes those requirements explicit feasibility gates before a full-container claim.

## What works today

- A top-edge AppKit panel that expands from the notch area and can temporarily cover part of the menu bar.
- A picker for ordinary running app windows, with ScreenCaptureKit capture and an IOSurface-backed Metal preview.
- Hover or click notch triggers, plus a menu-bar entry; compact/medium/wide sizes; picker/direct/last-used opening; fit/fill/native-scale content display. These choices are saved locally.
- The capture stream stops when the overlay closes. The source app continues running.
- A selected window is rechecked by process, launch time, bundle and window ID while the overlay is open. Closing it clears the preview; resizing it updates capture dimensions.

The preview says what it can do: "View only", or "Interactive (beta)" with the verified input kinds; unverified input is refused with a reason. Direct and last-used opening match a saved *app* and choose one of its current windows; they do not yet remember a particular document window. Dropy does not yet launch an app that is closed, pin installed apps, or select a crop region. Esc, the shortcut, click-outside and pointer-leave dismissal are checked with real input by `Scripts/dismissal-checks.sh`. Input is refused whenever the drawn frame cannot be tied to the selected window at its current size, for example during a resize or right after switching windows. The [compatibility matrix](docs/COMPATIBILITY.md) lists exactly what is verified.

## Build and run

With Xcode and a Swift 6 toolchain on macOS:

```sh
swift build
swift test
./Scripts/build-local.sh
open .build/local/Dropy.app
```

On the original development machine, the Command Line Tools installation lacks a SwiftPM framework, so `swift build` and `swift test` fail before compilation. The direct `swiftc` build script and `./Scripts/test-local.sh` work there; the local script also runs the XCTest suite through a minimal stand-in. The script assembles an ad-hoc-signed development `.app`; it is not a signed public release. macOS may request Screen Recording permission when a window is selected.

Dropy appears as a diamond in the menu bar. Use **Open Dropy** or the selected notch trigger, choose a running window, and close the panel from its **Close** button. Settings are in the menu-bar menu.

## Engineering direction

Capture, presentation, source-window tracking, input/focus and source placement are separate concerns. The capture path is implemented; exact-window input and keeping arbitrary source windows out of sight remain open. A controlled test activated one Accessibility-exposed button in an off-screen test app, but that does not establish general typing, scrolling, menus, IME or drag-and-drop. [Feasibility status](docs/FEASIBILITY.md) records what has and has not been shown.

Read [ROADMAP.md](ROADMAP.md) for milestones and pass/fail criteria, [ARCHITECTURE.md](ARCHITECTURE.md) for module boundaries, the [compatibility observations](docs/COMPATIBILITY.md) for actual app checks, and [CONTRIBUTING.md](CONTRIBUTING.md) to help. Security reports should follow [SECURITY.md](SECURITY.md). Windows is a later platform track with a separate backend.
