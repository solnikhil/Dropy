# Dropy device checks

- Date: 2026-09-30 03:14 IST
- Dropy: 42728d4 (uncommitted changes)
- macOS: 27.0 (26A428); hardware: Mac14,2
- Displays: 2560 x 1664 Retina
- TextEdit 1.21; Safari 27.0; Electron fixture not run
- Checks: safari; extra apps: none
- Desktop session: owner=device-checks; input idle 500.4s at start; power ac
- Desktop at start: active=4 frontmost=com.openai.codex; at end: active=4 frontmost=com.openai.codex

## Placement and recovery

| App | Check | Capture while placed | Driver result | Independent check |
|---|---|---|---|---|
| com.apple.Safari | offscreen | capture=[complete=+362] presented=+361 | windowServerLeak=0.016; restore=restored | restored; onscreen=1 visible=0.015682 uncovered=0.015682 tabs=0 |
| com.apple.Safari | parked | capture=[complete=+37] presented=+29 | windowServerLeak=0.000; restore=restored | restored; onscreen=1 visible=0.015682 uncovered=0.000000 tabs=1 |
| com.apple.Safari | minimize | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000; restore=restored | restored; onscreen=0 visible=0.000000 uncovered=0.000000 tabs=0 |
| com.apple.Safari | hideApp | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000; restore=restored | restored; onscreen=0 visible=0.000000 uncovered=0.000000 tabs=0 |
| com.apple.Safari | user move during offscreen | - | restore=keptUserChange | kept user move |
| com.apple.Safari | crash while parked | parked at 1670.0 974.0 800.0 440.0 0 0; journal=yes | placement recovery: mode=parked window=5903 outcome=restored | restored after crash |

Dismissal (Esc, shortcut, click-outside, pointer-leave, focus handback) is checked separately by `Scripts/dismissal-checks.sh`; input routing by `Scripts/interactive-checks.sh`.

## Manual: Screen Recording revocation

Needs Dropy's own grant, which ad-hoc builds lose on every rebuild: sign the build with an Apple-issued identity, launch it with `open`, allow it once, start a preview, then switch Dropy off in Screen & System Audio Recording. Expected: `failed.permissionDenied`, preview cleared, source app untouched.
