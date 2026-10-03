# Notch and window-first implementation

3 October 2026. Supersedes the implementation proposals in the earlier research snapshot; the HTML remains an illustrative exploration, not a screenshot of the native app.

## Implemented

- Three disjoint 12-point reachable regions: base, left shoulder and right shoulder. The physical housing is excluded. The regions are transparent input targets; they never paint separate rectangles around the physical housing. All edges can be clicked; hover mode also opens after a 220 ms rest.
- A pure monotonic hover session restarts intent on region changes and excessive movement. Drift followed by rest can open without an exit/re-entry. Closing waits for exit only when the pointer is actually inside. Cancellable, generation-tagged timers reject obsolete callbacks.
- An off-by-default **Experimental → Restrict sideways movement across the notch** preference. An active Quartz session event tap stops horizontal crossings at the approached shoulder. It requires Accessibility, bypasses Option and pressed mouse buttons, operates only on the same display, and is removed while the overlay is open. Moving below the housing remains unrestricted. A disabled/unavailable tap fails open; Settings reports runtime status. Permission is rechecked when Dropy becomes active. It does not claim to change macOS's physical housing exclusion.
- The chooser occupies the body until selection. A selected source replaces it with a full-width preview; no persistent branding, subtitle, Pin app, Refresh button or sidebar. A small app/window menu at the left of the housing changes the exact window; expansion sits to the right. The menu refreshes the catalog on opening, and its rows carry full window identity rather than indices. Pinning remains available in Settings.
- **Match the selected window’s size**, on by default. A 310 × 200-point source gets a 310 × 200 preview, 8-point side insets, the housing-height clearance and a 44-point capability footer. Oversized windows scale down proportionally to fit. Expand fills the available display budget, preserving aspect ratio with Fit. Existing Fit/Fill/Native scale choices remain; Fill can crop, so use Fit for the whole source.
- Source resizing updates the body during the existing exact-window watcher. Layout changes retain the Metal renderer and capture ownership, invalidate presented input mapping synchronously, settle obsolete outline animation, and update capture resolution through the existing stream configuration path.

The source app's own title bar is preserved. ScreenCaptureKit captures a window surface; a fixed title-bar crop would also crop custom tabs/toolbars and would require changes to both measured capture geometry and input mapping. It needs a separate per-window content-geometry design. Dropy's own branding/header has been removed from the preview body.

## Validation and remaining evidence

`Scripts/build-local.sh` compiles the application. `Scripts/test-local.sh` exercises the full local suite, including pure intent, barrier, sizing, preference migration and an AppKit workspace layout check that never shows a window. Existing input evidence and source-restoration checks stay in the suite.

The running application has not been replaced or launched, and hardware checks have not resumed. The cursor experiment uses public APIs but whether it removes visible jump/flicker on this Mac is unverified. Test with the experimental option both off and on before treating it as a UX improvement. Also verify menu-item conflicts beside the new shoulders, slow-motion opening/selection, menu catalog updates, changing source size, both dismissal modes, full screen and multiple displays.

Primary API references used during implementation:
- [Quartz event taps](https://developer.apple.com/documentation/coregraphics/cgevent)
- [Event-tap creation and active filters](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))
- [Screen safe-area geometry](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets)

## Screenshot correction and live metadata read

The supplied screenshot exposed a U-shaped artifact caused by painting each hit region black. Removed that painting; base/side activation stays intact and the physical housing supplies the resting silhouette. An AppKit regression check verifies clear backgrounds, no shadow and no focus stealing without showing windows.

Read-only window-server inspection found WhatsApp's main window 6663 owned by process 3403 at `(147, 122, 1200, 800)` points, on-screen, with the application not hidden. These are observed bounds, not a preset. For this display (1710 × 1112 points, housing clearance 37.5), the layout calculation yields a 1200 × 800 preview and a 1216 × 881.5 body including side insets and capability status.

Selection now resolves the exact window and refreshes its server geometry before changing the layout or starting capture. Each subsequent source check refreshes the size again. Visibility combines the exact window-server flag and app-hidden state; another display is not equated with minimized/hidden/another Space. A missing visibility flag is unknown, not evidence that capture paused.

Claude owns the animation work. No animation implementation, spring, timing, outline curve, resize-morph or relayout-content method was edited during this correction. The current animated layout entry point receives freshly measured source dimensions. The correction is compiled and tested locally; it has not replaced the running /Applications build.

## Opening-region boundary correction

The old base rectangle excluded its maximum-y boundary: a direct CoreGraphics check confirmed that a cursor at the housing's exact lower edge was outside the base. The hit test now includes that reachable boundary while still excluding the housing interior. One continuous transparent panel per notched display delivers tracking for all three logical regions, avoiding three independent window seams.

Post-close movement is observed temporarily until the pointer actually leaves the activation region. This covers an exit obscured by the fading overlay; the observer is removed on exit, opening, stopping or rebuilding. Trigger callbacks release their panels only after the controller confirms an opening, rather than hiding them before an opening can succeed.

The full local suite passed, including new exact-edge hover and continuous-tracking tests, plus the AppKit transparency check. No animation implementation or timing was changed. The running installed build has not been replaced by these checks.


## Latest hover, sizing and screen-edge correction

Supersedes the earlier tracking-panel and capability-footer designs above. Closed-state triggering now uses passive local/global mouse observers across all displays. It creates no invisible input windows; the three small logical targets retain exact-base inclusion, dwell and post-close exit rearming. Observation and dwell timers stop on confirmed opening. Pointer movement outside a target schedules no timer; steady-state mouse-event cost has not been measured.

The measured source dimensions now fit within the selected size preset. Compact is the new default; Expand bypasses that cap and uses the display budget. For the previously observed 1200 × 800 source, Compact calculates a 471.75 × 314.5 preview in a 487.75 × 360 body. The permanent capability footer is removed; the bottom inset is eight points. Unsupported input still follows existing verification gates and shows a transient refusal only when attempted. Settings uses a 480 × 560 scrollable content area and overrides oversized saved window dimensions.

Panel canvases align outward to backing-pixel boundaries. Borderless panel positioning retains the screen-top anchor instead of applying the ordinary menu-bar exclusion; child coordinates use the panel's actual frame. These are placement changes; Claude's animation curves, springs and timing were preserved.

The full local suite covers measured-source caps, expansion, hidden status by default, renderer retention, exact lower-edge hover, pixel alignment and top-band positioning. No HID, terminal capture or capture-permission requests were performed.

Installed the tested build at `/Applications/Dropy.app` on 2026-10-03 after comparing identical designated signing requirements with the existing installed app. Relaunched through LaunchServices; process 41979 has the new launch date. Only the saved size preset changed to Compact. Read-only window metadata confirms no former notch tracking panels and a visible Settings frame of 480 × 592 points (560-point content plus title bar). Live pointer interaction and animation appearance remain unverified; hardware automation and terminal capture were not resumed.
