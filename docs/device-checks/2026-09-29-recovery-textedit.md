# Dropy device checks

- Date: 2026-09-29 17:50 IST
- Dropy: 069ccec (uncommitted changes)
- macOS: 27.0 (26A428); hardware: Mac14,2
- Displays: 2560 x 1664 Retina
- TextEdit 1.21; Safari 27.0; Electron fixture not run
- Checks: textedit; extra apps: none
- Desktop session: owner=device-checks; input idle 81.4s at start
- Desktop at start: active=4 frontmost=com.apple.Terminal; at end: active=4 frontmost=com.apple.Terminal

## Placement and recovery

| App | Check | Capture while placed | Driver result | Independent check |
|---|---|---|---|---|
| com.apple.TextEdit | offscreen | capture=[complete=+151] presented=+6 | windowServerLeak=0.013; restore=restored | restored; onscreen=1 visible=0.013409 uncovered=0.013409 tabs=0 |
| com.apple.TextEdit | parked | capture=[complete=+130] presented=+11 | windowServerLeak=0.000; restore=restored | restored; onscreen=1 visible=0.013409 uncovered=0.000000 tabs=1 |
| com.apple.TextEdit | minimize | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000; restore=restored | restored; onscreen=0 visible=0.000000 uncovered=0.000000 tabs=0 |
| com.apple.TextEdit | hideApp | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000; restore=restored | restored; onscreen=0 visible=0.000000 uncovered=0.000000 tabs=0 |
| com.apple.TextEdit | user move during offscreen | - | restore=keptUserChange | kept user move |
| com.apple.TextEdit | crash while parked | parked at 1670.0 994.0 800.0 440.0 0 0; journal=yes | placement recovery: mode=parked window=1153 outcome=restored | restored after crash |

## Manual: dismissal

Click-outside and pointer-leave: NOT RUN. Open the overlay with each preference; click another app and the Dropy menu, then enter and leave the overlay. Confirm close and focus handback, and that shortcut-open with the pointer elsewhere stays open.

## Manual: Screen Recording revocation

Needs Dropy's own grant, which ad-hoc builds lose on every rebuild: sign the build with an Apple-issued identity, launch it with `open`, allow it once, start a preview, then switch Dropy off in Screen & System Audio Recording. Expected: `failed.permissionDenied`, preview cleared, source app untouched.
