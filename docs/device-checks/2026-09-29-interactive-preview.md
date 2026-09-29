# Dropy interactive preview checks

- Date: 2026-09-29 12:53 IST; revision: codex/m3-interactive-preview on 76872e9 (uncommitted at run time)
- macOS: 27.0 (26A428); real HID input on Dropy's preview of input-fixture window A while window B is the fixture's key window

| Source | Input | Result | Observed |
|---|---|---|---|
| visible | click | PASS | A=1 B=0; kind=pointerClick condition=visible route=windowTargetedEvent |
| visible | typing | PASS | A=3 B=0; kind=text condition=visible route=accessibility |
| visible | scroll | PASS | A=3 B=0; kind=scroll condition=visible route=windowTargetedEvent |
| visible | focus stays with Dropy | PASS | frontmost=org.dropy.app |
| offDisplay | click | PASS | A=1 B=0; kind=pointerClick condition=parked route=windowTargetedEvent |
| offDisplay | typing | PASS | A=3 B=0; kind=text condition=parked route=accessibility |
| offDisplay | scroll | PASS | A=3 B=0; kind=scroll condition=parked route=windowTargetedEvent |
| offDisplay | focus stays with Dropy | PASS | frontmost=org.dropy.app |
| TextEdit | click | PASS | caret A 0→330, B unchanged; kind=pointerClick condition=visible route=accessibility |
| TextEdit | typing | PASS | A +3 chars at the clicked caret, B unchanged; kind=text condition=visible route=accessibility |
| TextEdit | focus stays with Dropy | PASS | frontmost=org.dropy.app |
