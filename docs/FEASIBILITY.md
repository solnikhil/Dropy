# Feasibility status

## Observed in controlled local tests

- A borderless panel could occupy the MacBook top band and a separate AppKit window could be captured with ScreenCaptureKit.
- A captured frame's pixel buffer was IOSurface-backed. The native app rendered live Spotify and tldraw windows in a Metal preview after explicitly requesting BGRA output.
- A click in a controlled mirror panel invoked one Accessibility-exposed button in a separate test app.
- A specially configured test source window could sit fully off-screen, remain capturable, and accept that one Accessibility action. An ordinary `NSWindow` initially constrained its position so part remained visible. This does not establish a way to park arbitrary third-party windows.
- The native Dropy build currently shows live windows, but it does not forward interaction and it does not hide the original app window.

These checks were correctness observations, not frame-age, energy, battery or broad compatibility benchmarks. The current UI says **live preview** rather than *interactive app* for that reason.

## Source placement on ordinary windows (M2, first results)

TextEdit 1.21 on macOS 27.0 (M2 MacBook Air, built-in display), each placement undone through the journal. Mode results are from `DROPY_DEBUG_PLACEMENT`, run twice each. The clamp table comes from moving the window with Accessibility.

| Placement | Capture while placed | Visible on screen | Restored |
|---|---|---|---|
| Minimize | Stops (0 frames; preview paused) | Nothing | Yes, both runs |
| Hide app | Stops (0 frames; preview paused) | Nothing (but hides all of the app's windows) | Yes, both runs |
| Move off-screen, right | Continues (~110–200 frames in the hold) | 40 × 440 pt strip (5%) | Yes, both runs |
| Fully covered by another window | Continues (M1 check, ~165 s) | Nothing, but the cover occupies that screen area | Not needed |

AppKit clamps a moved foreign window so part of it stays reachable: 40 pt when pushed left or right, 118 pt when pushed below the screen, and it cannot go above the menu bar. The bottom-right corner leaves the smallest strip (40 × 118 pt, 1.3% for an 800 × 440 window), so off-screen placement now targets that corner. The corner target itself is not yet verified through the driver.

**Conclusion so far:** for an AppKit app, no public placement tested both keeps capture live and puts the whole window out of sight. Next experiments: other toolkits (WebKit, Electron/Chromium, media), which may clamp differently, and a tiny Dropy window covering the leftover corner strip, since covered windows keep capturing.

During the session, Accessibility began returning invalid window elements for every app (an `AXApplication` or `AXScrollArea` role in the windows list), even though `AXIsProcessTrusted` still reported true. The exact-window lookup then failed and Dropy refused to place anything, which is the intended behaviour. The cause is unknown.

## Platform facts and open questions

Apple documents desktop-independent window capture and its behavior when a window is occluded, off-screen or minimized. The stream can deliver GPU-backed frames, but it does not give Dropy ownership of another app's views or native event loop. Apple documents `CGEvent.postToPid` as process-targeted, and Accessibility actions as requests on exposed UI elements. Research has not found a documented public API for sending a complete native event stream to the exact foreign window represented by an `SCWindow` while that window is mirrored inside Dropy. This is an unresolved engineering question, not a claim of impossibility. [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [advanced capture session](https://developer.apple.com/videos/play/wwdc2022/10155/), [CGEvent posting](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)), [Accessibility actions](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction).

Menus, sheets, IME candidate windows and drag/drop may use surfaces and system interactions outside a selected main-window image. Apple's stream configuration exposes `includeChildWindows`, but the exact behavior needs tests for the chosen filter and each target workflow. [ScreenCaptureKit child windows](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/includechildwindows), [AppKit dragging sessions](https://developer.apple.com/documentation/appkit/nsdraggingsession).

Dropy therefore separates capture/presentation from input/focus and source placement. The [roadmap](../ROADMAP.md) defines the experiments and exit conditions before a broader compatibility claim.
