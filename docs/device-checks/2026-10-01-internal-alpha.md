# First integrated internal alpha test session — 2026-10-01

The user explicitly resumed device testing. These runs used the combined PR #37 branch at `7732db8`, with the live-preview label and device regression test corrections described below. They do not complete M3, M4 or release gates.

## Results

- [TextEdit containment and recovery](2026-10-01-textedit-recovery.md): all four modes restored the exact scratch window; a later move was preserved; crash recovery restored the parked window. The desktop remained unchanged on the successful rerun. Parking had zero uncovered area. Ordinary off-screen placement still exposed 1.3% of the source. Capture paused while minimized or hidden; restoration success does not imply live capture in those modes.
- [Interactive preview](2026-10-01-interactive-preview.md): exact-window click, scroll and typing passed against the disposable AppKit fixture while visible/covered and off-screen. Unsupported gestures and editing keys were refused, with no effect in the decoy. The double-click test failed because its first ordinary click was refused during a preview update. Electron fixture ordinary click/scroll and typing refusal passed, but its click during animation was also refused during a preview update. Safari page-button click, text-input refusal and focus retention passed. This Electron fixture is not a third-party compatibility gate.
- [Native router regressions](2026-10-01-router-regressions.txt): passed after correcting the harness to supply the fixture's already-verified covered condition. Geometry changes, stale/replaced fields, switching, hidden-source refusal, simulated trust loss and process relaunch were checked. The relaunch assertion now accepts the current-condition gate's `sourceConditionUnknown` refusal as well as exact-target `targetUnreachable`; all three sends must be refused and the relaunched app must remain unchanged. No production authorization gate was relaxed.
- [Dismissal](2026-10-01-dismissal.md): 8/8 passed, including the shortcut, Esc, click-outside, pointer-leave and focus handback.
- **TextEdit preview input failed in the tested covered condition.** Click and typing were refused, and both scratch documents remained unchanged. Raising both scratch windows did not resolve coverage: the [isolated retry](2026-10-01-textedit-input-retry.txt) records intersecting Wispr Flow and Dock windows. TextEdit 1.21 has evidence for visible and parked input, not covered input. Those apps were left alone; covered support was not inferred or enabled.

An earlier placement run was inconclusive after a desktop switch and TextEdit exit. Its local report remains in `.build/local/device-checks-20261001-131319.md`; the successful recovery result above is a separate rerun. The initial native harness failures are retained locally in `.build/local/interactive-checks-20261001-131636.md`; they are not counted as passes.

### Intermittent input availability failure

The combined end-to-end report contains **24 PASS and 4 FAIL rows**. Two failures are TextEdit covered click/typing described above. The other two are the first click of a double-click and an Electron press while animating: both saw “Preview updating · input not sent” and no effect in A or B. Those cases passed in the first run, so the later failures are retained as intermittent failures. Logs: [AppKit](2026-10-01-dropy-visible.log), [Electron](2026-10-01-dropy-electron.log). No retries were used to convert these rows into passes. The next reliability investigation should determine why current-frame authorization is unavailable at these inputs, retaining geometry, exact-window and changed-frame safety. These results do not justify weakening the freshness guard.

## Changes made during testing

- Removed the obsolete “interaction bridge not enabled yet” capture status. The capture line now says “Live preview”; the existing separate interaction label states actual enablement/support/refusal.
- Updated the native fixture regression evidence and relaunch assertion to match the current fail-closed classifier, preserving independent decoy and side-effect checks.
- Raised TextEdit scratch window A before B during setup, so both are placed above normal app windows before testing. Foreign overlay coverage remains observable and unsupported.

The full local suite and release rehearsal passed after the capture-label change. Subsequent device runs rebuilt the app and compiled/executed the updated native router regression test.

## Cleanup and outstanding gates

Scripts restored saved Dropy preferences. Final checks found no held modifiers, placement journal, device lock, running Dropy or test fixture. Scratch TextEdit windows were closed.

Still unverified in this session: real-window hand-off and its cancellation/reparking, visible GPU region selection, picker pins, new hidden-update labels, stream-stop retries and actual permission revocation, third-party Electron/media compatibility, full-screen/multiple displays, current latency/CPU budgets and signed distribution. No personal workspace was driven, no new application downloaded, and no signing identity or macOS permission changed. PR #37 remains unmerged.
