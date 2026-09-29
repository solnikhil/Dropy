# Dropy device checks

- Date: 2026-09-29 20:12 IST
- Dropy: 8db04ab (uncommitted changes)
- macOS: 27.0 (26A428); hardware: Mac14,2
- Displays: 2560 x 1664 Retina
- TextEdit 1.21; Safari 27.0; Electron fixture 43.2.0
- Checks: electron; extra apps: none
- Desktop session: owner=device-checks; input idle 416.0s at start
- Desktop at start: active=4 frontmost=com.openai.codex; at end: active=4 frontmost=com.openai.codex

## Placement and recovery

| App | Check | Capture while placed | Driver result | Independent check |
|---|---|---|---|---|
| org.dropy.electronfixture | offscreen | capture=[complete=+366,idle=+1] presented=+360 | windowServerLeak=0.024; restore=restored | restored; onscreen=1 visible=0.023887 uncovered=0.023887 tabs=0 |
| org.dropy.electronfixture | parked | capture=[complete=+66,idle=+1] presented=+21 | windowServerLeak=0.000; restore=restored | restored; onscreen=1 visible=0.023887 uncovered=0.000000 tabs=1 |
| org.dropy.electronfixture | minimize | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000; restore=restored | restored; onscreen=0 visible=0.000000 uncovered=0.000000 tabs=0 |
| org.dropy.electronfixture | hideApp | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000; restore=restored | restored; onscreen=0 visible=0.000000 uncovered=0.000000 tabs=0 |
| org.dropy.electronfixture | user move during offscreen | - | restore=keptUserChange | kept user move |
| org.dropy.electronfixture | crash while parked | parked at 1670.0 994.0 520.0 380.0 0 0; journal=yes | placement recovery: mode=parked window=3293 outcome=restored | restored after crash |
| org.dropy.electronfixture | parked recovery on another desktop (crash=no) | - | restore=restored | restored on another desktop |
| org.dropy.electronfixture | parked recovery on another desktop (crash=yes) | - | placement recovery: mode=parked window=3293 outcome=restored | restored on another desktop |

Dismissal (Esc, shortcut, click-outside, pointer-leave, focus handback) is checked separately by `Scripts/dismissal-checks.sh`; input routing by `Scripts/interactive-checks.sh`.

## Manual: Screen Recording revocation

Needs Dropy's own grant, which ad-hoc builds lose on every rebuild: sign the build with an Apple-issued identity, launch it with `open`, allow it once, start a preview, then switch Dropy off in Screen & System Audio Recording. Expected: `failed.permissionDenied`, preview cleared, source app untouched.
