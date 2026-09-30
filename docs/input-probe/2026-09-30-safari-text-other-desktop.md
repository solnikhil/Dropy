# Dropy text-semantics probe: safari

- Date: 2026-09-30 02:57 IST; revision: 42728d4 (uncommitted changes)
- macOS 27.0 (26A428); Mac14,2; target: Safari 27.0, window A 5437, decoy window B 5440
- Desktop session: owner=text-probe-safari; input idle 1262.0s at start; power ac; desktop at start active=4, at end active=4
- tally noEffect=8 notRun=14 pass=2 wrongWindow=4

Cases (Scripts/bench/text.html): middle = caret inside prefilled input, select = selection replaced, multi = caret inside line 2 of a textarea, edit = caret inside a contenteditable. `pass` = exact text and caret in A's field, an input event in A, A's other fields and all of B unchanged, no key-window, app, desktop or pointer change, nothing held. `partialEffect(...)` = A changed but not correctly; **wrongWindow** = B changed or received input. Undo is measured afterwards with the page's own undo.

| Route | Action | Case | otherSpace/bKey | otherSpace/appInactive |
|---|---|---|---|---|
| ax | type | middle | notRun(setupFocusMismatch) | noEffect |
| ax | type | select | notRun(setupFocusMismatch) | noEffect |
| ax | type | multi | notRun(setupFocusMismatch) | noEffect |
| ax | type | edit | notRun(setupFocusMismatch) | noEffect |
| axValue | type | middle | notRun(setupFocusMismatch) | noEffect |
| axValue | type | select | notRun(setupFocusMismatch) | noEffect |
| axValue | type | multi | notRun(setupFocusMismatch) | noEffect |
| axValue | type | edit | notRun(setupFocusMismatch) | pass (undo ok) |
| pidWindow | type | middle | notRun(setupFocusMismatch) | **wrongWindow(delivered)** |
| pidWindow | type | select | notRun(setupFocusMismatch) | **wrongWindow(delivered)** |
| pidWindow | type | multi | notRun(setupFocusMismatch) | **wrongWindow(delivered)** |
| pidWindow | type | edit | notRun(setupFocusMismatch) | **wrongWindow** |
| ax | click | - | notRun(setupFocusMismatch) | pass |
| pidWindow | click | - | notRun(setupFocusMismatch) | noEffect |
