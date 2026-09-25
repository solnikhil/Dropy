# Dropy

Dropy is a free, [MIT-licensed](LICENSE) macOS project building a temporary app container around the MacBook notch. The intended experience is to reveal an existing app's live UI in a Dropy-owned overlay, work there, and dismiss the overlay without losing the app's session.

**Current status: early native build, view-only.** Dropy can mirror a selected running window, but it does not yet route general interaction into that app or hide the app's original window. The [roadmap](ROADMAP.md) makes those requirements explicit feasibility gates before a full-container claim.

## What works today

- A top-edge AppKit panel that expands from the notch area and can temporarily cover part of the menu bar.
- A picker for ordinary running app windows, with ScreenCaptureKit capture and an IOSurface-backed Metal preview.
- Hover or click notch triggers, plus a menu-bar entry; compact/medium/wide sizes; picker/direct/last-used opening; fit/fill/native-scale content display. These choices are saved locally.
- The capture stream stops when the overlay closes. The source app continues running.
- A selected window is rechecked by process, launch time, bundle and window ID while the overlay is open. Closing it clears the preview; resizing it updates capture dimensions.

The preview is labelled as view-only in the UI. Direct and last-used opening match a saved *app* and choose one of its current windows; they do not yet remember a particular document window. Dropy does not yet launch an app that is closed, pin installed apps, select a crop region, or implement every dismissal mode.

## Build and run

With Xcode and a Swift 6 toolchain on macOS:

```sh
swift build
swift test
./Scripts/build-local.sh
open .build/local/Dropy.app
```

On the original development machine, the Command Line Tools installation lacks a SwiftPM framework, so `swift build` and `swift test` fail before compilation. The direct `swiftc` build script and `./Scripts/test-local.sh` work there. The script assembles an ad-hoc-signed development `.app`; it is not a signed public release. macOS may request Screen Recording permission when a window is selected.

Dropy appears as a diamond in the menu bar. Use **Open Dropy** or the selected notch trigger, choose a running window, and close the panel from its **Close** button. Settings are in the menu-bar menu.

## Engineering direction

Capture, presentation, source-window tracking, input/focus and source placement are separate concerns. The capture path is implemented; exact-window input and keeping arbitrary source windows out of sight remain open. A controlled test activated one Accessibility-exposed button in an off-screen test app, but that does not establish general typing, scrolling, menus, IME or drag-and-drop. [Feasibility status](docs/FEASIBILITY.md) records what has and has not been shown.

Read [ROADMAP.md](ROADMAP.md) for milestones and pass/fail criteria, [ARCHITECTURE.md](ARCHITECTURE.md) for module boundaries, the [compatibility observations](docs/COMPATIBILITY.md) for actual app checks, and [CONTRIBUTING.md](CONTRIBUTING.md) to help. Security reports should follow [SECURITY.md](SECURITY.md). Windows is a later platform track with a separate backend.
