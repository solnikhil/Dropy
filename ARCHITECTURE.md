# Dropy architecture and build gates

## Product contract

Dropy should expand from the MacBook notch across the top menu-bar band into a temporary, Dropy-owned container. A selected existing application keeps its session. The goal is to use that app's UI inside the container and dismiss Dropy without closing or corrupting the source app.

That full contract is **not yet implemented**. The first native slice is a live, view-only window mirror. With Full App interaction the app's real window is moved into the overlay; see the interaction section below.

## Current modules

| Module | Responsibility | Current state |
|---|---|---|
| `DropyCore/Preferences` | Durable choices for trigger, direct/last/picker opening, size, display mode and dismissal | Basic persisted settings; selected-region and several dismissal modes not yet exposed |
| `DropyCore/Geometry` | Top-edge display geometry and inverse image-coordinate mapping | Unit-checked for fit/fill and boundary cases |
| `DropyCore/WindowIdentity` | Session-local process/window identity; reject a reused ID after relaunch | Pure matching checks; never persisted as an app preference |
| `DropyCore/WindowPicker` | Choose pickable windows and give each a distinguishable label | Normal window layer only; no off-screen untitled helper fallback; same-label windows get a creation-order suffix; non-visible windows are marked |
| `DropyCore/CaptureLifecycle` | Capture phases, distinct failure reasons and stream-error classification | Unit-checked; log names carry no app names or titles |
| `WindowCatalog` | Discover and freshly resolve exact `SCWindow` objects belonging to ordinary running apps | Resolution reports available, window closed (exact process still running) or process exited; it does not filter by title or size |
| `CaptureController` | Start/stop one desktop-independent `SCStream`; own a bounded latest-frame mailbox | Runs only while a window is selected; reconfigures output on source resize; reports unexpected stream stops; a stopped stream's mailbox is invalidated so it cannot repaint |
| `MetalFrameView` | Import BGRA IOSurface-backed buffers as Metal textures and display fit/fill/native modes | Visually checked with Spotify, tldraw and TextEdit; clearing presents an empty pass; not profiled |
| `DropyCore/SourcePlacement` | Placement modes, journal entries, restore decisions and off-screen geometry | Unit-checked; a later user move always wins; an unplugged display falls back to the main display |
| `WindowPlacer` / `PlacementJournal` | M2 experiments: minimize, hide app or move off-screen, journaled before touching the window and restored on close, quit or next launch | Development driver only (`DROPY_DEBUG_PLACEMENT`), not in the product UI; exact window found via `_AXUIElementGetWindow` or refused |
| `OverlayController` | AppKit panel, picker, view-only state, source selection and lifecycle | Drives `CapturePhase`; rechecks the exact window every two seconds while capturing, reacts to app termination and stream stops; closes without quitting the source app |
| `AppDelegate` | Status menu, triggers, global shortcut, preferences | Notch hover/click or shortcut-only; ⌥⌘D toggles the overlay via a Carbon hot key (no Accessibility needed); dismiss mode menu |
| `DropyCore/MotionCurve`, `DropyAnimation` | How the overlay moves: each motion (open, resize, close) moves the outline's width and height along a curve (a spring or keyframes with eases); the content's reveal, cascade, blur and hide | Unit-checked; closing is always forward-only; the window margin follows the animation's reach |
| `DropyCore/AnimationFile`, `AnimationGuide`, `AnimationFilmstrip` | The animation file format: a forgiving reader with path-named problems and limits, a tidy writer, share codes, the guide for people and agents, and a picture of an animation | Unit-checked; every built-in style and example round-trips without an issue |
| `AnimationLibrary`, `AnimationStudio`, `AnimationDemo`, `AnimationCommand` | The watched animations folder, the Studio editor, playing an animation on the notch, and `Dropy animation …` in a terminal | The command line is checked by `test-local.sh` in a throwaway folder; the Studio was driven with real mouse input once |
| `DropyCore/Dismissal` | Which events end an overlay session for each dismiss mode | Unit-checked; Esc always closes; click-outside and pointer-leave watchers exist only while the overlay is open; focus returns to the previous app |

The overlay runs as closed → selecting → starting → viewing ⇄ paused, with one failed state that keeps its reason: permission denied or revoked, source window closed, target quit, stopped from the system screen-sharing controls, stream interrupted, or window list unavailable. Every failure goes through one path that invalidates in-flight work, stops the stream, clears the preview and repopulates the list for an explicit new choice. Paused means the exact window still exists but is minimized, hidden or on another Space, so ScreenCaptureKit is delivering no new frames. An unexpected stream stop is re-resolved to decide between a closed window, a quit app and a genuine interruption; a genuine interruption restarts once, and a stop from the system controls never restarts. An interaction-active state belongs to M3.

The window check runs only during capture. Its two-second ScreenCaptureKit catalog refresh is a correctness guard for window close and resize, not a measured final cadence; the M1 benchmark must include its WindowServer and energy cost. App termination also has an immediate workspace notification. The stream delegate usually reports a closed window or quit app before the next poll. A vanished source clears the preview and requires an explicit new choice, avoiding a silent switch to another same-title document.

## Capture and rendering decision

Use the public `SCContentFilter(desktopIndependentWindow:)` and `SCStream` APIs. Request a window-sized BGRA stream limited to the preview's needed pixel density. Keep the callback short: retain only the newest pending `CVPixelBuffer`, schedule one main-thread handoff, and allow the renderer to import its `IOSurface` as an `MTLTexture`. Do not turn each frame into a `CGImage` or encode and decode it for local display.

The initial live visual check exposed a real format mismatch: ScreenCaptureKit supplied `420v` by default while the first Metal importer treated the surface as BGRA. The image tiled. Explicitly requesting `kCVPixelFormatType_32BGRA` corrected the preview. No claim of zero-copy or low latency follows from a correct image; profiling must measure the complete loop and all processes involved. [Apple's capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [Metal IOSurface import](https://developer.apple.com/documentation/metal/mtldevice/maketexture%28descriptor%3Aiosurface%3Aplane%3A), [advanced capture session](https://developer.apple.com/videos/play/wwdc2022/10155/).

## Interaction: the real window in the overlay (decision, 2026-10-07)

Dropy does not forward input. Measured on macOS 27 (see [feasibility](docs/FEASIBILITY.md)), keyboard events always follow an app's key window, menus, popovers, sheets and input-method windows open beside the real window wherever it is, and apps throttle a hidden window. A bridge from a picture to a hidden window therefore cannot give normal interaction, and every app and version would need its own evidence. The earlier input bridge (`InputRouter`, verified-evidence routing, in-preview typing) was removed on 2026-10-07; its probe reports remain in `docs/input-probe` as history.

Instead, **Full App** interaction docks the real window:

1. **Opening.** The outline grows from the notch showing a snapshot of the window (`SCScreenshotManager`). Once it covers the window's place, `WindowDock` moves and sizes the real window into the hole below the notch band through Accessibility (journaled first as `PlacementMode.docked`), makes it main and raises it, and sets its app frontmost (Accessibility `AXFrontmost`, falling back to cooperative activation with `yieldActivation`). The outline is then cut open over the window (`MorphBackdropView.hole`) and the snapshot fades over the identical real window.
2. **In use.** The overlay panel is non-activating and ignores the pointer except over its own outline (the band with the controls, and the border). Nothing streams. Clicks inside the app, its menus, the menu bar and system panels it opens keep the overlay (`DockPolicy.clickIsInside`); another app coming to the front closes it (`DockPolicy.activationCloses`). Esc belongs to the app; the shortcut toggles. Resizing the window moves the outline with it; dragging it away, full screen or minimizing hands it to the person.
3. **Closing.** A fresh snapshot covers the window's place while the window goes back to the frame the journal recorded, then the outline closes. Focus returns to the previous app if the person was still in the docked one. A window the person minimized or hid while docked is put back to its frame and stays minimized or hidden. Quitting Dropy or a crash restores it the same way.

### The Stage and Live mode (2026-10-08)

A window cannot be moved between desktops with public API, but it can be moved between displays, and it lands on the destination display's current desktop. Dropy therefore owns a hidden virtual display, the **Stage** (`Stage`, through the `DropyStageShim` wrapper of CoreGraphics' private `CGVirtualDisplay`). It is created at launch for Full App with "Keep Pinned App Ready" on, sized like the notch display, placed past the bottom-right corner of every display so it touches them at one point, guarded by an event tap against a stray pointer, and covered by an opaque curtain while nothing on it is shown so its apps idle. Measurements: [stage spike results](docs/design/2026-10-07-stage-spike-results.md).

- **Pinned app, Native.** Closing moves the pinned app's window to its slot on the Stage (`PlacementMode.staged`) instead of its original place; the next opening moves it from the Stage into the notch on whatever desktop the person is on. A window found on another desktop is pulled over through the Stage. Quitting puts it back to its original frame.
- **Live, over a full-screen app** (`LiveSession`). An ordinary window cannot join another app's full-screen space, so the window stays on the Stage, uncovered, and `LiveCaster` streams the Stage region it occupies (a display region, so its menus and popovers show). `PointerHandoff` moves the real pointer onto the Stage while it is over the cast and back when it leaves; `SoftCursor` draws the app's cursor in the overlay; the app is brought to the front, so the keyboard needs no forwarding. macOS shows its screen-recording indicator while Live is open.
- **Mode choice** is `SessionModePolicy` (Preview without Accessibility or by choice; Live when the notch display shows a full-screen space and the Stage is usable; Native otherwise). "Displays have separate Spaces" off disables the Stage.

Without the Stage (unsupported macOS, the switch off, shared Spaces), a window on another desktop cannot be brought over: the overlay shows its snapshot and offers to go there, and a full-screen space gets the view-only preview.

Pure decisions are in `DropyCore/DockGeometry.swift`, `DockPolicy.swift`, `StageGeometry.swift`, `PointerHandoff.swift` and `SessionModePolicy.swift`, each unit-tested; the AppKit side is `WindowDock`, `NativeSession`, `LiveSession`, `LiveCaster`, `Stage` and `PreviewSession`, hosted by `OverlayController`.

## Animations (2026-10-09)

One format, many ways to write it. An animation is a JSON file (`docs/ANIMATIONS.md`); the built-in styles, the gallery, the Animation Studio, share codes and AI agents all produce the same `DropyAnimation`, and the overlay plays only that. So there is one place for the rules:

- **Two parts per motion.** Width (and the ears where the outline meets the screen edge) and height (and the lower corners) each follow a `MotionCurve` from 0 to 1. Springs keep their physics; keyframes join with a monotone smooth curve (no swing past a key, flat at peaks) or a named or custom timing curve.
- **Closing is forward-only.** `NotchMorph.Motions` and `DropyAnimation` mark the close motion monotonic, so no curve can make the outline bounce back out of the camera housing.
- **Limits, not trust.** `AnimationLimits` bounds every value; the reader brings values inside with a warning and speeds up a motion that runs too long. The overlay window's margin comes from the animation's actual reach, so an overshoot is never clipped.
- **The same code everywhere.** The content's reveal, relayout and hide run on plain layers (`OverlayMotion.reveal` and friends), so the overlay, the notch demo and the Studio's stage play an animation identically.
- **Files are the source of truth.** `AnimationLibrary` watches the folder with FSEvents; the Studio autosaves, and takes in a change made elsewhere while it is open. A chosen file with errors falls back to the chosen built-in style, and Settings says why.
- **Agents are first-class.** The folder carries README.md (the guide) with AGENTS.md and CLAUDE.md pointing to it. `Dropy animation` (the app binary run from a terminal) checks, renders, plays (through a distributed notification to the running app), creates, selects and shares animations.

## Source-window placement boundary

ScreenCaptureKit documents capture of covered and off-screen windows, with minimization pausing. The controlled off-screen experiment worked only after its source window subclass overrode AppKit's default frame constraint; the ordinary test window was clamped so 40 points remained visible. Dropy cannot change another app's `NSWindow` subclass. Hiding, minimizing, moving to another Space, off-screen Accessibility positioning and virtual display placement each need separate tests with real apps. A failure must leave the source app accessible through normal macOS controls.

## Quality and release gates

1. **Correctness:** exact source window, correct fit/fill pixel geometry, menu-bar overlap and dismissal, source survival on Dropy close, recovery from source quit and stream failure.
2. **Interaction:** passing matrix above before the word *interactive* is used in the UI or release notes.
3. **Placement:** out-of-sight source with no leaked controls, dialogs or duplicate UI, or an honest compatibility level when containment cannot be delivered.
4. **Performance:** warm reveal, first frame, frame age, input-to-updated-frame, stale/dropped frames, idle and active CPU/GPU, memory, wakeups, WindowServer cost and battery on dated hardware/OS/workloads. The [benchmark page](docs/BENCHMARK.md) defines the in-app metrics and clock checks, the reproducible workloads, the first baseline and provisional budgets.
5. **Platform:** menu bar crowding, full-screen Spaces, Stage Manager, mixed-DPI displays, unplug/rearrangement, notchless Macs, permission denial/revocation and protected content.
6. **Open source:** choose and publish a license, audit dependency notices, reproducible build and a versioned compatibility matrix before public release. Windows will need a separate platform backend.

The public [feasibility record](docs/FEASIBILITY.md) and [roadmap](ROADMAP.md) hold the current product boundary and validation plan. Detailed device-specific experiment logs remain in the local research workspace.
