> Reviewer note: six standard recovery checks passed. The requested additional cross-desktop check could not switch desktops and is NOT RUN. The script exited 1; this is not counted as a fully passing seven-check run.

# Dropy device checks

- Date: 2026-09-29 19:54 IST
- Dropy: 6c74a78 (uncommitted changes)
- macOS: 27.0 (26A428); hardware: Mac14,2
- Displays: 2560 x 1664 Retina
- TextEdit 1.21; Safari 27.0; Electron fixture not run
- Checks: textedit; extra apps: none
- Desktop session: owner=device-checks; input idle 356.2s at start
- Desktop at start: active=4 frontmost=com.openai.codex; at end: active=4 frontmost=com.openai.codex

## Placement and recovery

| App | Check | Capture while placed | Driver result | Independent check |
|---|---|---|---|---|
| com.apple.TextEdit | offscreen | capture=[complete=+154] presented=+6 | windowServerLeak=0.013; restore=restored | restored; onscreen=1 visible=0.013409 uncovered=0.013409 tabs=0 |
| com.apple.TextEdit | parked | capture=[complete=+94] presented=+15 | windowServerLeak=0.000; restore=restored | restored; onscreen=1 visible=0.013409 uncovered=0.000000 tabs=1 |
| com.apple.TextEdit | minimize | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000; restore=restored | restored; onscreen=0 visible=0.000000 uncovered=0.000000 tabs=0 |
| com.apple.TextEdit | hideApp | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000; restore=restored | restored; onscreen=0 visible=0.000000 uncovered=0.000000 tabs=0 |
| com.apple.TextEdit | user move during offscreen | - | restore=keptUserChange | kept user move |
| com.apple.TextEdit | crash while parked | parked at 1670.0 994.0 800.0 440.0 0 0; journal=yes | placement recovery: mode=parked window=2650 outcome=restored | restored after crash |
| com.apple.TextEdit | other desktop (no crash) | - | - | NOT RUN: cannot switch desktop |

Dismissal (Esc, shortcut, click-outside, pointer-leave, focus handback) is checked separately by `Scripts/dismissal-checks.sh`; input routing by `Scripts/interactive-checks.sh`.

## Manual: Screen Recording revocation

Needs Dropy's own grant, which ad-hoc builds lose on every rebuild: sign the build with an Apple-issued identity, launch it with `open`, allow it once, start a preview, then switch Dropy off in Screen & System Audio Recording. Expected: `failed.permissionDenied`, preview cleared, source app untouched.
