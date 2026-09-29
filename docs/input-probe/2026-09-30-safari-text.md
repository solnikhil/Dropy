# Dropy text-semantics probe: safari

- Date: 2026-09-30 01:43 IST; revision: 4b53f78
- macOS 27.0 (26A428); Mac14,2; target: Safari 27.0, window A 4561, decoy window B 4564
- Desktop session: owner=text-probe-safari; input idle 89.8s at start; power ac
- tally noEffect=92 notRun=28 partialEffect=8 pass=26

Cases (Scripts/bench/text.html): middle = caret inside prefilled input, select = selection replaced, multi = caret inside line 2 of a textarea, edit = caret inside a contenteditable. `pass` = exact text and caret in A's field, an input event in A, A's other fields and all of B unchanged, no key-window, app, desktop or pointer change, nothing held. `partialEffect(...)` = A changed but not correctly; **wrongWindow** = B changed or received input. Undo is measured afterwards with the page's own undo.

| Route | Action | Case | visible/aKey | visible/bKey | visible/appInactive | covered/bKey | covered/appInactive | parked/bKey | parked/appInactive | otherSpace/bKey | otherSpace/appInactive | minimized/bKey | minimized/appInactive |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ax | type | middle | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | noEffect | noEffect |
| ax | type | select | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | noEffect | noEffect |
| ax | type | multi | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | noEffect | noEffect |
| ax | type | edit | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | noEffect | noEffect |
| axValue | type | middle | pass (undo ok) | partialEffect(otherField) | partialEffect(otherField) | partialEffect(otherField) | partialEffect(otherField) | partialEffect(otherField) | partialEffect(otherField) | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | partialEffect(otherField) | partialEffect(otherField) |
| axValue | type | select | pass (undo ok) | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | noEffect | noEffect |
| axValue | type | multi | pass (undo ok) | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | noEffect | noEffect |
| axValue | type | edit | pass (undo ok) | pass (undo ok) | pass (undo ok) | pass (undo ok) | pass (undo ok) | pass (undo ok) | pass (undo ok) | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | pass (undo ok) | pass (undo ok) |
| pidWindow | type | middle | pass (undo ok) | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | noEffect | noEffect |
| pidWindow | type | select | pass (undo ok) | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | noEffect | noEffect |
| pidWindow | type | multi | pass (undo ok) | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | noEffect | noEffect |
| pidWindow | type | edit | pass (undo ok) | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | noEffect | noEffect |
| ax | click | - | pass | pass | pass | pass | pass | pass | pass | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | pass | pass |
| pidWindow | click | - | pass | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | notRun(otherSpaceNeedsOwnWindowMove) | notRun(otherSpaceNeedsOwnWindowMove) | noEffect | noEffect |
