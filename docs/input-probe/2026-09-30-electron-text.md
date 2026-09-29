# Dropy text-semantics probe: electron

- Date: 2026-09-30 01:31 IST; revision: 50bb832 (uncommitted changes)
- macOS 27.0 (26A428); Mac14,2; target: Electron 43.2.0 (Chromium 150.0.7871.129), window A 4425, decoy window B 4426
- Desktop session: owner=text-probe-electron; input idle 201.9s at start; power ac
- tally noEffect=69 partialEffect=30 pass=15 wrongWindow=40

Cases (Scripts/bench/text.html): middle = caret inside prefilled input, select = selection replaced, multi = caret inside line 2 of a textarea, edit = caret inside a contenteditable. `pass` = exact text and caret in A's field, an input event in A, A's other fields and all of B unchanged, no key-window, app, desktop or pointer change, nothing held. `partialEffect(...)` = A changed but not correctly; **wrongWindow** = B changed or received input. Undo is measured afterwards with the page's own undo.

| Route | Action | Case | visible/aKey | visible/bKey | visible/appInactive | covered/bKey | covered/appInactive | parked/bKey | parked/appInactive | otherSpace/bKey | otherSpace/appInactive | minimized/bKey | minimized/appInactive |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ax | type | middle | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect |
| ax | type | select | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect |
| ax | type | multi | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect |
| ax | type | edit | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect |
| axValue | type | middle | pass (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) | partialEffect(value) | partialEffect(value) | partialEffect(value) |
| axValue | type | select | pass (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) | partialEffect(value) | partialEffect(value) | partialEffect(value) |
| axValue | type | multi | pass (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) (undo fails) | partialEffect(value) | partialEffect(value) | partialEffect(value) | partialEffect(value) |
| axValue | type | edit | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect |
| pidWindow | type | middle | pass (undo fails) | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow** | **wrongWindow** |
| pidWindow | type | select | pass (undo fails) | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow** | **wrongWindow** |
| pidWindow | type | multi | pass (undo fails) | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow** | **wrongWindow** |
| pidWindow | type | edit | pass (undo fails) | **wrongWindow** | **wrongWindow** | **wrongWindow** | **wrongWindow** | **wrongWindow** | **wrongWindow** | **wrongWindow** | **wrongWindow** | **wrongWindow** | **wrongWindow** |
| ax | click | - | pass | pass | pass | pass | pass | pass | pass | noEffect | noEffect | noEffect | noEffect |
| pidWindow | click | - | pass | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect |
