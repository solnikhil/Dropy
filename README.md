# Dropy

[![macOS CI](https://github.com/solnikhil/Dropy/actions/workflows/ci.yml/badge.svg)](https://github.com/solnikhil/Dropy/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black)

**Dropy keeps an app one keystroke away, in the MacBook notch.** Press the shortcut and the app you picked drops out of the notch. It's the real app, so typing, menus, shortcuts, input methods and dragging all work as usual. Close it and the app goes back to where it was, with its session intact.

Dropy is free, open source and native (Swift, AppKit, ScreenCaptureKit, Metal).

> **Status: early development, no signed download yet.** You can build and run it from source today. A notarized release with automatic updates is being prepared; see [where things stand](#status).

## What it does

- **Opens a real window in the notch.** Pick an app and Dropy moves its window into an overlay that grows from the notch, then brings the app to the front. Nothing is emulated or forwarded.
- **Works on every desktop.** A pinned app waits on a hidden display Dropy creates (the *Stage*) between openings, so it opens on whatever desktop you're on.
- **Works over full-screen apps.** Over a full-screen app, the window is streamed into the overlay (*Live*) and the pointer is handed to it.
- **Puts everything back.** Every move is journaled before it happens. Closing the overlay, quitting Dropy or a crash returns each window to its original frame.
- **Favorites and shortcuts.** Keep a list of favorite apps, each with an optional Control–Option–1…9 shortcut and its own size and position.
- **Your own animations.** Three built-in styles plus an Animation Studio for springs, keyframes and hand-drawn curves. Animations are small JSON files, shareable as a one-line code, and AI coding agents can write them ([format](docs/ANIMATIONS.md)).
- **Respects protected video.** Dropy avoids screen capture while a video player is active, so streaming apps keep playing.
- **Signed automatic updates** through [Sparkle](https://sparkle-project.org) once a release channel is published ([details](docs/UPDATES.md)).

Without Accessibility permission, or with **Preview only** chosen, Dropy shows a live, view-only picture of the window instead.

## Requirements

- macOS 15 or later on Apple silicon. A notch is not required, but it's what Dropy is designed around.
- **Accessibility** permission, to move and focus the real window.
- **Screen Recording** permission, for the view-only preview and Live mode.

Dropy can't be sandboxed and isn't headed for the Mac App Store: it moves other apps' windows and uses a private CoreGraphics API (`CGVirtualDisplay`) for the Stage. Without that API it falls back to working on the current desktop only.

## Build and run

You need Xcode (or the Command Line Tools) with a Swift 6 toolchain.

```sh
git clone https://github.com/solnikhil/Dropy.git
cd Dropy
./Scripts/build-local.sh          # builds .build/local/Dropy.app
open .build/local/Dropy.app
```

To install it like an ordinary app in `/Applications` (Spotlight, Dock, Open at Login), run `./Scripts/install.sh`.

Open Dropy with **⌥Space** (the default shortcut) or from the menu bar. Press Esc, ⌘W or the shortcut again to close it. Everything else is in **Settings** (⌘,). A short setup tour runs on first launch and is available again from **Help › Setup…**.

Opening by hovering over or clicking the notch is built but turned off for now while the shortcut flow is refined.

## Status

Dropy works every day on its author's Mac, but it hasn't been tested widely. The [roadmap](ROADMAP.md) tracks milestones and their exit criteria, and the [compatibility log](docs/COMPATIBILITY.md) records what has been tested on real hardware.

| Area | State |
|---|---|
| Native docking, Stage, Live | Built; smoke-tested with TextEdit and Safari |
| Favorites, shortcuts, per-app layout | Built |
| Animation Studio and format | Built |
| Overlay positions (edges, corners) | Built; needs a device tryout |
| Multiple displays, Stage Manager | Not handled yet |
| Signed, notarized download | Not yet: needs a Developer ID certificate |
| Automatic updates | Code done; no release channel published yet |

## How it's built

```
Sources/
  DropyCore/       Pure logic: geometry, policies, animation format, preferences (unit-tested)
  Dropy/           The AppKit app: overlay, sessions, Stage, capture, settings, updates
  DropyStageShim/  Objective-C wrapper for the private virtual-display API
Tests/             XCTest suite for DropyCore, plus local integration checks
Scripts/           Build, install, test, benchmark, device-check and release scripts
docs/              Design records, feasibility notes, compatibility log, benchmarks
```

Decisions go in `DropyCore` as plain values with tests. The AppKit side carries them out. [ARCHITECTURE.md](ARCHITECTURE.md) covers the module boundaries, the docking, Stage and Live designs, and the quality gates.

## Contributing

Contributions are welcome. Small fixes, compatibility reports from real apps and Macs, and focused experiments are all useful. Start with [CONTRIBUTING.md](CONTRIBUTING.md), then look for issues labelled [`good first issue`](https://github.com/solnikhil/Dropy/labels/good%20first%20issue) or [`help wanted`](https://github.com/solnikhil/Dropy/labels/help%20wanted). Ask questions in [Discussions](https://github.com/solnikhil/Dropy/discussions).

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

## Privacy

Dropy has no accounts, analytics or telemetry. Captured pixels, window titles and text stay on your Mac and are never logged by default. The only network request is the update check, which goes to the published release feed.

## License

[MIT](LICENSE). Sparkle is distributed under its own license ([ThirdParty/Sparkle-LICENSE](ThirdParty/Sparkle-LICENSE)).
