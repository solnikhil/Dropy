# Dropy

Dropy is a macOS utility being built for a free, open-source release. Its goal is to expand the MacBook notch into a temporary container for an existing application's live UI. Dismissing Dropy should leave the source app running and its session intact. A public license still needs to be selected before release.

## Current build

The first native slice has a notch-anchored panel, running-window picker, persistent trigger, size, open-behavior and content-view settings, a ScreenCaptureKit window stream, and a Metal preview. The preview is **view-only**. A controlled test outside the app proved one Accessibility button action, but did not establish general mouse, keyboard, menu, IME, or drag-and-drop routing. The source app's own window currently remains visible elsewhere on the desktop. Do not describe this build as an arbitrary-app interactive container.

The code separates preferences/geometry, window discovery, capture, presentation, and overlay lifecycle. Input routing and source-window placement are explicit future modules, gated by the experiments in the [research record](../outputs/dropy-device-feasibility-check.md).

## Build locally

The repository includes a Swift package manifest for full Xcode/SwiftPM installations. This machine's Command Line Tools installation currently lacks `BuildServerProtocol.framework`, so `swift test` and `swift build` fail before package compilation. The local build script compiles the same sources directly with `swiftc` and assembles a temporary `.app` bundle:

```sh
./Scripts/build-local.sh
./Scripts/test-local.sh
open .build/local/Dropy.app
```

The app lives in the menu bar. Choose **Open Dropy**, or hover at the notch to reveal it, then choose a running window. Screen Recording permission may be requested by macOS. The overlay closes from its **Close** button or menu item. Size and open behavior are available in the status menu. This is a local development build, ad-hoc signed; it is not a distributable release.

## Architecture and release gates

- Capture only the selected window while the overlay is open. The frame callback keeps one latest buffer and drops older pending frames.
- Present IOSurface-backed pixel buffers through Metal. This avoids the test harness's CPU image conversion, but no end-to-end copy or latency claim has been benchmarked yet.
- Keep capture, input, focus, and source-window placement as separate adapters. The latter three remain unresolved for a general app.
- Validate exact-window input, original-window visibility, menus/dialogs/IME/drag-and-drop, multi-display/full-screen behavior, permissions, recovery, and performance before promising the full product experience.

The [tldraw scope](../outputs/Dropy%20-%20Product%20and%20Build%20Scope.tldraw) and [findings](../outputs/dropy-findings-explained.md) carry the product contract and investigation plan.
