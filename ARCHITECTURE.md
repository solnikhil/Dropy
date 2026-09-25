# Dropy architecture and build gates

## Product contract

Dropy should expand from the MacBook notch across the top menu-bar band into a temporary, Dropy-owned container. A selected existing application keeps its session. The goal is to use that app's UI inside the container and dismiss Dropy without closing or corrupting the source app.

That full contract is **not yet implemented**. The first native slice is a live, view-only window mirror. The selected app's own window remains visible on the desktop. The repository intentionally does not fake general interactivity with a single Accessibility button action.

## Current modules

| Module | Responsibility | Current state |
|---|---|---|
| `DropyCore/Preferences` | Durable choices for trigger, direct/last/picker opening, size, display mode and dismissal | Basic persisted settings; selected-region and several dismissal modes not yet exposed |
| `DropyCore/Geometry` | Top-edge display geometry and inverse image-coordinate mapping | Unit-checked for fit/fill and boundary cases |
| `WindowCatalog` | Discover exact `SCWindow` objects belonging to ordinary running apps | Filters system/accessory windows and empty-title duplicates |
| `CaptureController` | Start/stop one desktop-independent `SCStream`; own a bounded latest-frame mailbox | Runs only while a window is selected in an open overlay |
| `MetalFrameView` | Import BGRA IOSurface-backed buffers as Metal textures and display fit/fill/native modes | Visually checked with Spotify and tldraw; not profiled |
| `OverlayController` | AppKit panel, picker, view-only state, source selection and lifecycle | Opens at the screen top; closes without quitting the source app |
| `AppDelegate` | Status menu, hover/click trigger, preferences | Menu bar entry and basic settings |

The overlay state should eventually be modeled as a stricter state machine: closed → opening → source resolving → capture starting → viewing → interaction active → closing, plus distinct permission, target-quit, stream-interrupted and recovery states. The current `State` enum is only the first lifecycle boundary.

## Capture and rendering decision

Use the public `SCContentFilter(desktopIndependentWindow:)` and `SCStream` APIs. Request a window-sized BGRA stream limited to the preview's needed pixel density. Keep the callback short: retain only the newest pending `CVPixelBuffer`, schedule one main-thread handoff, and allow the renderer to import its `IOSurface` as an `MTLTexture`. Do not turn each frame into a `CGImage` or encode and decode it for local display.

The initial live visual check exposed a real format mismatch: ScreenCaptureKit supplied `420v` by default while the first Metal importer treated the surface as BGRA. The image tiled. Explicitly requesting `kCVPixelFormatType_32BGRA` corrected the preview. No claim of zero-copy or low latency follows from a correct image; profiling must measure the complete loop and all processes involved. [Apple's capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [Metal IOSurface import](https://developer.apple.com/documentation/metal/mtldevice/maketexture%28descriptor%3Aiosurface%3Aplane%3A), [advanced capture session](https://developer.apple.com/videos/play/wwdc2022/10155/).

## Interaction boundary

The selected `SCWindow.windowID` identifies capture content; it does not provide a documented public event endpoint for a complete foreign-window pointer/keyboard stream. Process-targeted mouse events failed in the initial controlled test. A panel click plus `AXPress` did activate one exposed button, including when a specially configured test source was moved entirely off-screen. That does not imply text input, IME composition, menu routing, custom canvas hit testing or drag-and-drop support. [Apple's `postToPid`](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)), [Accessibility actions](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction).

Before enabling an input adapter in the product, test same-app windows A and B under different focus states; left/right click, hover, wheel, keyboard shortcuts, selection, text/IME, menus, sheets, dialogs and drag/drop; then repeat with AppKit, browser/WebKit, Electron and music apps. Record the exact window receiving the action and any focus or visible-window transition. Declare support per app and workflow, not by one successful click.

## Source-window placement boundary

ScreenCaptureKit documents capture of covered and off-screen windows, with minimization pausing. The controlled off-screen experiment worked only after its source window subclass overrode AppKit's default frame constraint; the ordinary test window was clamped so 40 points remained visible. Dropy cannot change another app's `NSWindow` subclass. Hiding, minimizing, moving to another Space, off-screen Accessibility positioning and virtual display placement each need separate tests with real apps. A failure must leave the source app accessible through normal macOS controls.

## Quality and release gates

1. **Correctness:** exact source window, correct fit/fill pixel geometry, menu-bar overlap and dismissal, source survival on Dropy close, recovery from source quit and stream failure.
2. **Interaction:** passing matrix above before the word *interactive* is used in the UI or release notes.
3. **Placement:** out-of-sight source with no leaked controls, dialogs or duplicate UI, or an honest compatibility level when containment cannot be delivered.
4. **Performance:** warm reveal, first frame, frame age, input-to-updated-frame, stale/dropped frames, idle and active CPU/GPU, memory, wakeups, WindowServer cost and battery on dated hardware/OS/workloads.
5. **Platform:** menu bar crowding, full-screen Spaces, Stage Manager, mixed-DPI displays, unplug/rearrangement, notchless Macs, permission denial/revocation and protected content.
6. **Open source:** choose and publish a license, audit dependency notices, reproducible build and a versioned compatibility matrix before public release. Windows will need a separate platform backend.

The public [feasibility record](docs/FEASIBILITY.md) and [roadmap](ROADMAP.md) hold the current product boundary and validation plan. Detailed device-specific experiment logs remain in the local research workspace.
