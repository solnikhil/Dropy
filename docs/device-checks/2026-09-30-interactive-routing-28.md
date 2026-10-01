# Dropy interactive preview checks

- Date: 2026-09-30 07:43 IST; revision: ac1eab4
- macOS: 27.0 (26A428); real HID input on Dropy's preview of input-fixture window A while window B is the fixture's key window

| Source | Input | Result | Observed |
|---|---|---|---|
| visible | click | PASS | A=1 B=0; kind=pointerClick condition=visible route=windowTargetedEvent |
| visible | modified click refused | PASS | A=0 B=0 |
| visible | typing | PASS | A=3 B=0; kind=text condition=visible route=accessibility |
| visible | scroll | PASS | A=3 B=0; kind=scroll condition=visible route=windowTargetedEvent |
| visible | right-click (context menu) refused | PASS | A=0/0 B=0/0; shown="Right-click not sent: not verified for this app here" |
| visible | double-click: second click refused | PASS | A=1 B=0; A=2/1 B=0/0; shown="Click not sent: not verified for this app here" |
| visible | drag refused | PASS | A=0/0 B=0/0; shown="Drag not sent: not verified for this app here" |
| visible | Option-scroll refused | PASS | A=0/0 B=0/0; shown="Scroll not sent: not verified for this app here" |
| visible | Command-K shortcut refused | PASS | A=0/0 B=0/0; shown="Shortcut not sent: not verified for this app here" |
| visible | left arrow (editing key) refused | PASS | A=0/0 B=0/0; shown="This key is not supported in the preview yet" |
| visible | delete (editing key) refused | PASS | A=0/0 B=0/0; shown="This key is not supported in the preview yet" |
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
| Electron | click while animating | PASS | A=1 B=0 |
| Electron | typing refused | PASS | A=0 B=0; kind=text condition=visible refused=notVerified |
| Electron | focus stays with Dropy | PASS | frontmost=org.dropy.app |
| Safari | button click | PASS | A "presses":1, B "presses":0; kind=pointerClick condition=visible route=accessibility target=pressable |
| Safari | text click and typing refused | PASS | A and B inputs unchanged; kind=pointerClick condition=visible refused=notVerified target=text; kind=text condition=visible refused=notVerified |
| Safari | focus stays with Dropy | PASS | frontmost=org.dropy.app |

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
PASS typing after Accessibility is revoked is refused
PASS a click after Accessibility is revoked is refused
PASS a scroll after Accessibility is revoked is refused
PASS revoked permission sent nothing
PASS input to an updated app version is refused
PASS input to an unknown app version is refused
PASS version mismatch sent nothing
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
