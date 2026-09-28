# Dropy device checks

- Date: 2026-09-29 02:03 IST
- Dropy: branch codex/space-aware-source-recovery (uncommitted at run time; the committed tree matches)
- macOS: 27.0 (26A428); hardware: Mac14,2
- Displays: 2560 x 1664 Retina
- TextEdit 1.21; Safari 27.0
- Checks: fixture; extra apps: none
- Desktop at start: active=4 frontmost=com.apple.Terminal; at end: active=1 frontmost=net.imput.helium

## Placement and recovery

| App | Check | Capture while placed | Driver result | Independent check |
|---|---|---|---|---|
| org.dropy.fixture | offscreen | capture=[complete=+358] presented=+187 | windowServerLeak=0.017; restore=restored | restored; onscreen=1 visible=0.017072 uncovered=0.017072 tabs=0 |
| org.dropy.fixture | parked | capture=[complete=+215] presented=+136 | windowServerLeak=0.000; restore=restored | restored; onscreen=1 visible=0.017072 uncovered=0.000000 tabs=1 |
| org.dropy.fixture | minimize | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000; restore=restored | restored; onscreen=0 visible=0.000000 uncovered=0.000000 tabs=0 |
| org.dropy.fixture | hideApp | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000; restore=restored | restored; onscreen=0 visible=0.000000 uncovered=0.000000 tabs=0 |
| fixture | parked, moved to another desktop | window while away: mainOrFocusedOnly:space:otherSpace | restore=restored | restored on the other desktop |
| fixture | parked, moved to another desktop, not main | window while away: space:otherSpace | restore=deferred(windowUnreachable(onOtherSpace)); then restored | kept the record while away, restored automatically on return |
| fixture | parked, moved to another desktop, not main, Dropy killed | window while away: space:otherSpace | outcome=deferred(windowUnreachable(onOtherSpace)); then restored | kept the record while away, restored automatically on return |

## Manual: dismissal

Click-outside and pointer-leave: NOT RUN. Open the overlay with each preference; click another app and the Dropy menu, then enter and leave the overlay. Confirm close and focus handback, and that shortcut-open with the pointer elsewhere stays open.

## Manual: Screen Recording revocation

Needs Dropy's own grant, which ad-hoc builds lose on every rebuild: sign the build with an Apple-issued identity, launch it with `open`, allow it once, start a preview, then switch Dropy off in Screen & System Audio Recording. Expected: `failed.permissionDenied`, preview cleared, source app untouched.

## Negative control: same fixture checks on 82e8911 (before this change)

| App | Check | Capture while placed | Driver result | Independent check |
|---|---|---|---|---|
| org.dropy.fixture | offscreen | capture=[complete=+363] presented=+190 | windowServerLeak=0.017; restore=restored | restored; onscreen=1 visible=0.017072 uncovered=0.017072 tabs=0 |
| org.dropy.fixture | parked | capture=[complete=+79] presented=+48 | windowServerLeak=0.000; restore=restored | restored; onscreen=1 visible=0.017072 uncovered=0.000000 tabs=1 |
| org.dropy.fixture | minimize | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000; restore=restored | restored; onscreen=0 visible=0.000000 uncovered=0.000000 tabs=0 |
| org.dropy.fixture | hideApp | capture=[complete=+0,suspended=+0] presented=+0 | windowServerLeak=0.000; restore=restored | restored; onscreen=0 visible=0.000000 uncovered=0.000000 tabs=0 |
| fixture | parked, moved to another desktop | window while away: mainOrFocusedOnly:space:otherSpace | restore=pending | FAILED: restore=pending, window at 120.0 540.0 640.0 432.0 0 0, journal present=no |
| fixture | parked, moved to another desktop, not main | window while away: space:otherSpace | no deferral; then  | FAILED: deferred=none journalWhileAway=yes retry=none window at 120.0 540.0 640.0 432.0 0 0, journal present=no |
| fixture | parked, moved to another desktop, not main, Dropy killed | window while away: space:otherSpace | no deferral; then  | FAILED: deferred=none journalWhileAway=yes retry=none window at 120.0 540.0 640.0 432.0 0 0, journal present=no |
