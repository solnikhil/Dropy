# Dropy device checks

- Date: 2026-09-28 00:40 IST
- Dropy: cc10967
- macOS: 27.0 (26A428); hardware: Mac14,2
- Displays: 2560 x 1664 Retina
- TextEdit 1.21; Safari 27.0

## Placement and recovery

| App | Check | Capture while placed | Driver result | Independent check |
|---|---|---|---|---|
| com.apple.TextEdit | offscreen | capture=[complete=+150] presented=+6 | windowServerLeak=0.013 | restored |
| com.apple.TextEdit | parked | capture=[complete=+29] presented=+9 | windowServerLeak=0.000 | restored |
| com.apple.TextEdit | minimize | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000 | restored |
| com.apple.TextEdit | hideApp | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000 | restored |
| com.apple.TextEdit | user move during offscreen | - | restore=keptUserChange | kept user move |
| com.apple.TextEdit | crash while parked | parked at 1670 994 800 440 0; journal=yes | placement recovery: mode=parked outcome=restored | restored after crash |
| com.apple.Safari | offscreen | capture=[complete=+3,idle=+1] presented=+3 | windowServerLeak=0.016 | NOT restored (gone vs 80 560 800 440 0) |
| com.apple.Safari | parked |  | failed=windowNotInAccessibilityTree | NOT restored (gone vs 80 560 800 440 0) |
| com.apple.Safari | minimize |  | failed=windowNotInAccessibilityTree | NOT restored (gone vs 80 560 800 440 0) |
| com.apple.Safari | hideApp |  | failed=windowNotInAccessibilityTree | NOT restored (gone vs 80 560 800 440 0) |

## Manual: Screen Recording revocation

Needs Dropy's own grant, which ad-hoc builds lose on every rebuild: sign the build with an Apple-issued identity, launch it with `open`, allow it once, start a preview, then switch Dropy off in Screen & System Audio Recording. Expected: `failed.permissionDenied`, preview cleared, source app untouched.
