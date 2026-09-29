# Dropy interactive preview checks

- Date: 2026-09-29 18:28 IST; revision: 3e083be
- macOS: 27.0 (26A428); real HID input on Dropy's preview of input-fixture window A while window B is the fixture's key window

| Source | Input | Result | Observed |
|---|---|---|---|
| visible | click | PASS | A=1 B=0; kind=pointerClick condition=visible route=windowTargetedEvent |
| visible | modified click refused | PASS | A=0 B=0 |
| visible | typing | PASS | A=3 B=0; kind=text condition=visible route=accessibility |
| visible | scroll | PASS | A=3 B=0; kind=scroll condition=visible route=windowTargetedEvent |
| visible | focus stays with Dropy | PASS | frontmost=org.dropy.app |
| offDisplay | click | PASS | A=1 B=0; kind=pointerClick condition=parked route=windowTargetedEvent |
| offDisplay | modified click refused | PASS | A=0 B=0 |
| offDisplay | typing | PASS | A=3 B=0; kind=text condition=parked route=accessibility |
| offDisplay | scroll | PASS | A=3 B=0; kind=scroll condition=parked route=windowTargetedEvent |
| offDisplay | focus stays with Dropy | PASS | frontmost=org.dropy.app |
| TextEdit | click | PASS | caret A 0→330, B unchanged; kind=pointerClick condition=visible route=accessibility |
| TextEdit | typing | PASS | A +3 chars at the clicked caret, B unchanged; kind=text condition=visible route=accessibility |
| TextEdit | focus stays with Dropy | PASS | frontmost=org.dropy.app |
| Electron | click | PASS | A=1 B=0; kind=pointerClick condition=visible route=accessibility |
| Electron | scroll | PASS | A=3 B=0; kind=scroll condition=visible route=windowTargetedEvent |
| Electron | typing refused | PASS | A=0 B=0; kind=text condition=visible refused=notVerified |
| Electron | focus stays with Dropy | PASS | frontmost=org.dropy.app |

## Router regressions

Direct `InputRouter` sends against the input fixture (Tests/DeviceInputRouterCheck.swift).

```
PASS click mapped for a stale size is refused
PASS a refused click chooses no typing target
PASS source resized for the check
PASS click during a source resize is refused
PASS scroll during a source resize is refused
PASS source size restored
PASS click at the current size is sent
PASS typing after the click is sent
PASS typing reached A only
PASS switching to B does not reuse A's typing target
PASS rapid switching leaves no typing target behind
PASS rapid switching sent nothing
PASS typing into a replaced field is refused
PASS stale target sent nothing
PASS a stale target is dropped, not retried
PASS pointer never moved
PASS frontmost app unchanged
PASS desktop unchanged
PASS source hidden for the check
PASS input to a hidden source is refused
Native router regressions passed
PASS old identity refused after relaunch
PASS old identity refused after relaunch
PASS old identity refused after relaunch
PASS no typing target survives a relaunch
PASS relaunched instance untouched
Native router regressions passed
```
