# Dropy

Dropy is a free, [MIT-licensed](LICENSE) macOS project building a temporary app container around the MacBook notch. The intended experience is to reveal an existing app's live UI in a Dropy-owned overlay, work there, and dismiss the overlay without losing the app's session.

**Current status: early native build.** Pick an app and Dropy moves its real window into the notch overlay and brings the app to the front, so typing, shortcuts, menus, input methods and dragging all work as usual. Nothing is forwarded or emulated. A **pinned** app waits on a hidden display Dropy creates (the Stage) between openings, so it opens on any desktop; over a full-screen app it is streamed into the overlay instead (**Live**), with the pointer handed over to it and its app in front. Any other window you pick goes back exactly where it was when the overlay closes, and quitting Dropy puts everything back. This needs Accessibility; without it, or with **Preview only** chosen, Dropy shows a live, view-only picture of the window. The Stage relies on a private CoreGraphics API (`CGVirtualDisplay`) and falls back to the behavior above without it. See the [roadmap](ROADMAP.md) for what is still open.

## What works today

- **Animations you can make your own.** Three built-in styles (Rapid, Balanced, Smooth) and any number of your own, made in the **Animation Studio** (Settings › Animation): springs you shape by dragging one handle, keyframes on a timeline, or a curve you draw with the pen, previewed live and on the real notch. Every animation is a small JSON file in `~/Library/Application Support/Dropy/Animations`, picked up the moment it is saved, shareable as a one-line code. AI coding agents (Claude Code, Codex, Cursor) can make them too: Settings copies a prompt, the folder carries the guide, and `Dropy animation check | render | play | use` lets an agent check its file, look at it and show it to you. Format and rules: [docs/ANIMATIONS.md](docs/ANIMATIONS.md).

- A top-edge AppKit panel that expands from the notch area and can temporarily cover part of the menu bar.
- A picker for ordinary running app windows, with ScreenCaptureKit capture and an IOSurface-backed Metal preview.
- Hover or click notch triggers, plus a menu-bar entry; compact/medium/wide sizes; picker/direct/last-used opening; fit/fill/native-scale content display. These choices are saved locally.
- The capture stream stops when the overlay closes. The source app continues running.
- A selected window is rechecked by process, launch time, bundle and window ID while the overlay is open. Closing it clears the preview; resizing it updates capture dimensions.

The preview stays free of a persistent capability footer; attempted unverified input is refused with a transient reason. Direct and last-used opening match a saved *app* and choose one of its current windows; they do not yet remember a particular document window. Dropy does not yet launch an app that is closed, pin installed apps, or select a crop region. Esc, the shortcut, click-outside and pointer-leave dismissal are checked with real input by `Scripts/dismissal-checks.sh`. Input is refused whenever the drawn frame cannot be tied to the selected window at its current size, for example during a resize or right after switching windows. The [compatibility matrix](docs/COMPATIBILITY.md) lists exactly what is verified.

## Notch and window-first UI (local changes, 2026-10-03)

The reachable base and both shoulders open Dropy by click or settled hover. A selected window now occupies the preview body, with app/window switching beside the housing and an expand control opposite it. Pinning remains in Settings; the persistent Pin app and Refresh buttons are removed. The window menu refreshes the catalog when opened.

**Fit the window within the selected size** preserves small source windows at native point size below the housing and scales larger windows down to the selected Compact/Medium/Wide budget. Compact is the default. Use Fit to show the whole source; Expand uses more of the display. The source app's title bar remains part of its captured window.

**Experimental → Restrict sideways movement across the notch** is off by default, requires Accessibility, and releases while the overlay is open. Hold Option to bypass it, or move below the notch. It is compiled and covered by policy tests; its effect on native cursor jumps has not yet been checked on hardware. See the [implementation record](docs/design/2026-10-03-implementation.md).

## Build and run

With Xcode and a Swift 6 toolchain on macOS:

```sh
swift build
swift test
./Scripts/build-local.sh
open .build/local/Dropy.app
```

On the original development machine, the Command Line Tools installation lacks a SwiftPM framework, so `swift build` and `swift test` fail before compilation. The direct `swiftc` build script and `./Scripts/test-local.sh` work there; the local script also runs the XCTest suite through a minimal stand-in. The script assembles an ad-hoc-signed development `.app`; it is not a signed public release. macOS may request Screen Recording permission when a window is selected.

To install it like an ordinary app (Spotlight, Launchpad, Dock, login item), run `./Scripts/install.sh`. It builds Dropy, copies it to `/Applications` (or `~/Applications`) and opens it.

Dropy shows a Dock icon, its own menu bar, and a diamond in the menu bar. Use **Open Dropy**, ⌥⌘D or the selected notch trigger, choose a running window, and close the panel with Esc, ⌘W or its **Close** button. **Settings…** (⌘,) holds every option, Open at login, Show in Dock and the permission status; opening Dropy again from Finder or the Dock also shows it. Turn off **Show in Dock** for a menu-bar-only app. Launches by the check scripts (`DROPY_DEBUG_*` or `--show`) always stay menu-bar-only.

## Engineering direction

Capture, presentation, source-window tracking, input/focus and source placement are separate concerns. The capture path is implemented; exact-window input and keeping arbitrary source windows out of sight remain open. A controlled test activated one Accessibility-exposed button in an off-screen test app, but that does not establish general typing, scrolling, menus, IME or drag-and-drop. [Feasibility status](docs/FEASIBILITY.md) records what has and has not been shown.

Read [ROADMAP.md](ROADMAP.md) for milestones and pass/fail criteria, [ARCHITECTURE.md](ARCHITECTURE.md) for module boundaries, the [compatibility observations](docs/COMPATIBILITY.md) for actual app checks, and [CONTRIBUTING.md](CONTRIBUTING.md) to help. Security reports should follow [SECURITY.md](SECURITY.md). Windows is a later platform track with a separate backend.
