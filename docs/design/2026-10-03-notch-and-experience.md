# Notch interaction and experience direction

Research and design exploration, 3 October 2026. Source reviewed; no device reproduction performed. The existing device-check pause in ROADMAP.md remains in effect. Companion: `experience-exploration.html` (illustrative layouts, no capture or source-window interaction).

## What explains the reported notch behavior

The physical camera housing, the drawn outline, and the trigger's hit region are three separate geometries. Changing NotchShape's bottom/ear radius changes drawing, not NotchTrigger's input region.

| Observation | Source evidence | Conclusion |
| --- | --- | --- |
| Right-to-left cursor jump | No cursor warp call found in Sources. Geometry.swift and HoverIntentTests explicitly describe macOS jumping across the housing. | Consistent with OS pointer avoidance, but not reproduced in this investigation. Dropy should accommodate the reachable edges, not promise to make the housing traversable. |
| Moving upward from the middle stops | Current source assumes pointer exclusion from the housing. notchReach adds only 6 points below the housing. | An upward approach must activate a visible, reachable base below the physical housing; input inside the housing cannot be a requirement. |
| Left/right activation fails | notchReach retains exactly notch.minX and notch.width. NotchTrigger's header still claims it covers side edges. Tests intentionally exclude side points. | Confirmed design/code mismatch: sides are not activation targets today. This was deliberate to prevent accidental openings after a sideways jump. |
| Hover becomes unresponsive after movement | pointerEntered schedules one 220 ms check. Failure clears pendingHover but schedules no retry. TrackingView receives entry/exit, not movement. | Confirmed state gap: entering, drifting more than 24 points, then resting cannot trigger until a fresh entry. |
| Closing can leave hover unarmed | overlayClosed always sets waitingForExit, even when the pointer is already outside the small trigger. Only a subsequent exit clears it. | Possible extra enter/exit cycle on reopening. Requires a lifecycle test against real panel ordering. |

Apple documents safeAreaInsets and auxiliaryTopLeftArea as display geometry; these establish the housing bounds, not a promise about pointer traversal:
- https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets
- https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc?language=_1

## Recommended foundation

Treat base, left and right as three activation regions feeding one session state machine. Keep the physical housing excluded. Retain one geometry model for the visual affordance and reachable hit regions; do not tie hit testing to animation spring overshoot.

1. **Base:** a visible lip beneath the housing, with a forgiving approach region. Start by exploring a 12-point depth; final dimensions need device checks rather than a hard-coded model assumption.
2. **Left/right:** visible shoulders extending into usable display space. Explore 12-point widths. Side click can open immediately; side hover must confirm a resting pointer after crossing, never a mere landing on the far shoulder. Check menu-item conflicts before shipping shoulders.
3. **Intent:** idle → candidate(region, anchor, deadline) → open → cooldown. Movement beyond drift resets the candidate's anchor/deadline. A settled pointer gets another chance without leaving. An inter-region jump resets intent. Exiting cancels the candidate.
4. **Rearm:** closing inspects the current pointer against the union of reachable regions. Wait for an exit only if it is actually inside. After cooldown, establish intent from fresh input. Changing screens, mode or panel visibility invalidates candidate work.
5. **Event adapter:** keep movement observation scoped to activation regions on notched screens. Do not introduce always-on global monitoring just to repair hover. Separate local event delivery from the pure intent reducer, using monotonic elapsed time and cancellable/generation-tagged deadlines.
6. **Window ownership:** the trigger must not swallow menu-bar clicks outside the visible affordance, become key, or intercept overlay input after opening. Define ownership of trigger and expanded panel explicitly.

This is a proposed design, not a landed behavior change. A radius increase or simple rectangle widening alone would restore the accidental-open problem already represented in existing tests.

## Acceptance gates for implementation

Pure tests: all three region boundaries; housing excluded; upward dwell; drift then rest retries; side jump resets dwell; region transitions; exit cancellation; close inside/outside; cooldown; stale timers; trigger-mode and display changes. Use asymmetric and translated screen coordinates, not only the measured 14-inch display.

Device checks when resumed: both traversal directions, upward approach at center and corners, slow versus fast movement, clicking each visible region, menu items beside both shoulders, overlay opening under the pointer, manual versus pointer-leave dismissal, full screen, scaled display, external/notchless display, disconnect and reconnect. Capture timestamps, region and lifecycle transitions; avoid recording window titles or captured content. Compare with Dropy quit to isolate OS pointer behavior.

## Current UI audit

OverlayController.buildContent fixes a 252-point window list beside the preview, keeps branding/subtitle and Refresh visible, and positions controls with literal frames. That gives selection, preview and operational controls equal emphasis and reserves the same sidebar width at every size. Capture, lifecycle, selection and presentation are concentrated in one controller.

Settings already groups Opening, Overlay, App and Permissions, but its pinned-app footer says all clicks/typing come later while another section offers verified interactive preview. README also says pinning/launching are absent, although SettingsModel.choosePinnedApp and OverlayController.showPinnedApp implement related paths. Documentation and UI copy need a code-backed capability audit before redesign labels are finalized.

## Experience direction

Use two main surfaces: **Choose an app** and **Use a window**. The chooser shows app identity, document/window identity and recent selections; selecting an app with multiple windows opens its window list, never silently chooses an arbitrary document. The workspace gives the live preview most of the area and exposes switching through a compact app rail or chooser button. Keep capability status attached to the selected window.

Interpret “prop section” as properties/settings for this exploration; confirm the meaning before implementing its contents.

| Surface | Proposed layout | Interaction contract |
| --- | --- | --- |
| Resting notch | Physical housing plus visible base/shoulders | Same accessible action from all three reachable regions; shortcut/menu alternative remains |
| App chooser | Search, pinned/recent apps, app rows with window counts | Keyboard navigation, explicit window selection, loading/empty states |
| Workspace | Small app/window header, large preview, compact bottom capability row | Switching preserves exact-window identity; stale capture disables input immediately |
| Properties | Optional inspector: display, size and opening/dismissal choices | Local view settings separate from global startup/permissions; change without covering the selected preview at compact widths |
| Recovery | Contextual message in preview area | Distinguish permission denied, source closed, capture interrupted and refused input; give one relevant action |

The companion exploration switches between chooser, workspace and properties layouts, compact/expanded widths, and several capability/recovery states. Sample app/document rows are illustrative. It does not imply new interaction support.

## Order of work

1. Implement reachable-region geometry and the intent reducer behind the existing trigger preference. Land meaningful core tests before changing AppKit event delivery.
2. Wire the adapter and verify event/window ownership; resume hardware checks by an explicit user decision.
3. Extract overlay presentation into dedicated chooser, workspace, inspector and recovery views. Keep capture/input/placement coordinators independent, preserving the current exact-window safety gates.
4. Introduce semantic appearance/spacing/motion tokens, adaptive layouts, keyboard focus and accessibility descriptions. Preserve the current Metal rendering path and animation performance constraints.
5. Audit every preference/copy line against actual behavior, migrate stored choices only where semantics change, then run supported journeys across widths and app capability states.

Success is a reliable entrance followed by a clear task-focused workspace, not a cosmetic expansion of the existing control panel.
