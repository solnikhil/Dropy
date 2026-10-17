# Daily workspace improvements — 2026-10-17

## Favorites and opening

Settings → Opening holds an ordered collection of favorite apps. Add installed apps, remove them, move them earlier/later, and choose a default. “Use Opening Choice” clears the default without deleting favorites and restores the picker/saved-app/last-used opening setting. Old single-pin preferences appear as a favorite and keep their previous opening behavior.

The overlay's window menu lists favorites even when their apps are closed. Choosing one launches or reopens it, waits up to twelve seconds for a window, and reports an unavailable app/window. The same menu offers Search Windows to return to the full picker. Enable Favorite Shortcuts to open the first nine favorites with Control–Option–1 through Control–Option–9. Registration checks system conflicts and reports unavailable shortcuts in Settings; the main toggle shortcut remains separate. Reordering favorites changes those assignments.

Only one favorite is kept ready on the hidden Stage at a time. Switching favorites restores the previous app through the same serialized window-operation queue used for dismissal. Other windows may wait there temporarily for their home desktop to become reachable. A collection of favorites does not mean every app is launched or placed on a virtual display at startup.

## Exact window memory

Dropy saves one recent window per app, capped at thirty apps. A record contains bundle identifier, process ID, process launch date, window ID and last-use time. It contains no title, document path or captured content. Every automatic selection must match the entire identity. If the recorded document closed or the process relaunched, Dropy asks for an explicit new window choice. Without a record, an app with one eligible window opens directly; several windows require a choice.

Forget Windows in Settings clears these records. This also clears recent-window ordering; favorite apps and presentation choices remain.

Each favorite can override the global size preset and overlay position, or inherit either global setting. These affect Dropy's presentation, not the original frame saved in its recovery journal. Source restoration must continue to use the original frame.

## Picker

Search matches every whitespace-separated word against the app name and window title, ignoring case and diacritics. Favorites sort in their configured order, followed by exact recent windows, followed by the catalog's stable app/document order. Up/Down changes the highlighted visible row; Return opens that exact identity. Digits entered into the search field are search text. An empty result says so and cannot activate an invisible row. Menus retain all catalog windows independently of the search filter.

## Reliability and display transitions

- Overlapping catalog refreshes cannot let an older result replace a newer one.
- Showing a previously hidden/minimized source saves a journal record before either mutation; restoration restores those flags as well as the frame.
- Live placement saves its intended geometry before moving, then confirms observed geometry. A failed journal write is an error, not permission to move the window anyway.
- Minimized/hidden source returns use the normal journal/restore path and retain recovery evidence on failure.
- Sleep, lock/session loss and real display topology, Retina scale or refresh-rate changes close the session and queue release of owned Stage windows. Merely adding/removing Dropy's Stage must not count as a hardware-display change. Dock auto-hide changes must not cause a close loop.
- Recovery retries when a display reconnects or the user session resumes, in addition to the existing Space/application/wake events.
- Live layout changes block pointer handoff until the latest window placement completes; an older completion cannot change the newer pointer transform. A missing first rendered frame fails the opening rather than revealing a blank interactive surface.

## Validation boundary

Local builds and deterministic tests can establish migration, search/selection policy, journal persistence and queued ownership behavior. They do not establish that another app's menus, IME, drag-and-drop, full-screen Spaces, Stage Manager or mixed-DPI display transitions work correctly on hardware. Follow [USER-VALIDATION.md](USER-VALIDATION.md) for those workflows; leave untested combinations marked untested. The earlier pause on device/capture checks remains in effect until explicitly lifted. Do not infer fresh device compatibility evidence from this implementation.

## Local verification

`Scripts/test-local.sh` passed on 2026-10-17 against the final source: the application build, 203 core test methods (including eleven new workspace/Live-layout methods), journal/recovery checks, workspace layout checks, queued session ownership including system-release/favorite-reopen ordering, and the remaining app-side regression checks. `git diff --check` passed. The local core suite uses the repository's XCTest shim; these are not fresh hardware compatibility results. No development app was launched, foreign app was exercised, capture permission requested, or Stage created for this verification.

## Opening on another desktop (2026-10-18)

Space notifications now distinguish an unknown WindowServer snapshot from a confirmed desktop change. Creating the hidden Stage can temporarily make the current Space unavailable; that alone must not cancel an opening. If the initial Space is unknown, the first known value establishes the baseline. A later change between known desktops still dismisses the old session.

The main shortcut and favorite shortcuts compare the requested physical display/desktop with the open session. When they differ, the old session is closed without stealing focus and a new session opens where the person is working, preserving the selected app. On the same desktop, the shortcut still toggles normally. A pointer currently handed onto the hidden Stage resolves back to the overlay's physical display rather than opening a second overlay on the Stage.

These policies have five deterministic regression tests. Real-app Space switching and full-screen interaction remain subject to the hardware-validation boundary above.
