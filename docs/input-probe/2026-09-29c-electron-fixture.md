# Dropy exact-window input probe

- Date: 2026-09-29 17:36 IST; revision: 069ccec (uncommitted changes)
- macOS: 27.0 (26A428); hardware: Mac14,2
- Target: org.dropy.electronfixture chrome:150.0.7871.129 electron:43.2.0 window A; decoy: window B of the same app
- Desktop session: owner=input-probe-electron; input idle 505.0s at start
- tally noEffect=55 notApplicable=14 notSent=12 pass=66 wrongWindow=45

Cells: `pass` = effect in A only; **wrongWindow** = effect in B (fail); `noEffect` = nothing happened;
notes: front = frontmost app changed and was not restored, key = A's key state changed, desktop = active desktop changed, pointer = the pointer moved, cached = A reached through an element resolved earlier (verified by window ID); MODIFIER/BUTTON HELD = the trial left a modifier or mouse button down (released, trial failed).

| Route | Action | visible/aKey | visible/bKey | visible/appInactive | covered/bKey | covered/appInactive | parked/aKey | parked/bKey | parked/appInactive | otherSpace/bKey | otherSpace/appInactive | minimized/bKey | minimized/appInactive |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pid | type | pass | **wrongWindow** | **wrongWindow** | **wrongWindow** | **wrongWindow** | pass | **wrongWindow** | **wrongWindow** | **wrongWindow** (cached) | **wrongWindow** (cached) | **wrongWindow** | **wrongWindow** |
| pid | click | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect (cached) | noEffect (cached) | noEffect | noEffect |
| pid | scroll | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect (cached) | noEffect (cached) | noEffect | noEffect |
| pid | shortcut | pass | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow(delivered)** | pass | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** (cached) | **wrongWindow(delivered)** (cached) | **wrongWindow** | **wrongWindow(delivered)** |
| pidWindow | type | pass | **wrongWindow** | **wrongWindow** | **wrongWindow** | **wrongWindow** | pass | **wrongWindow** | **wrongWindow** | **wrongWindow** (cached) | **wrongWindow** (cached) | **wrongWindow** | **wrongWindow** |
| pidWindow | click | pass | noEffect (focus,key) | noEffect | noEffect (focus,key) | noEffect | pass | noEffect (focus,key) | noEffect | noEffect (focus,key,cached) | noEffect (cached) | noEffect | noEffect |
| pidWindow | scroll | pass | pass | pass | pass | pass | pass | pass | pass | noEffect (cached) | noEffect (cached) | noEffect | noEffect |
| pidWindow | shortcut | pass | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow(delivered)** | pass | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** (cached) | **wrongWindow(delivered)** (cached) | **wrongWindow** | **wrongWindow(delivered)** |
| activate | type | pass | pass (focus,key) | pass (focus) | pass (focus,key) | pass (focus) | pass | pass (focus,key) | pass (focus) | pass (focus,key,desktop,cached) | pass (focus,desktop,cached) | notApplicable(minimized) | notApplicable(minimized) |
| activate | click | pass | pass (focus,key) | pass (focus) | pass (focus,key) | pass (focus) | notApplicable(pointOffDisplay) | notApplicable(pointOffDisplay) | notApplicable(pointOffDisplay) | pass (focus,key,desktop,cached) | pass (focus,desktop,cached) | notApplicable(minimized) | notApplicable(minimized) |
| activate | scroll | pass | pass (focus,key) | pass (focus) | pass (focus,key) | pass (focus) | notApplicable(pointOffDisplay) | notApplicable(pointOffDisplay) | notApplicable(pointOffDisplay) | pass (focus,key,desktop,cached) | pass (focus,desktop,cached) | notApplicable(minimized) | notApplicable(minimized) |
| activate | shortcut | pass | pass (focus,key) | pass (focus) | pass (focus,key) | pass (focus) | pass | pass (focus,key) | pass (focus) | pass (focus,key,desktop,cached) | pass (focus,desktop,cached) | notApplicable(minimized) | notApplicable(minimized) |
| ax | type | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect (cached) | noEffect (cached) | noEffect | noEffect |
| ax | click | pass | pass | pass | pass | pass | pass | pass | pass | pass (cached) | pass (cached) | pass | pass |
| ax | scroll | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) (cached) | notSent(elementNotFound) (cached) | notSent(elementNotFound) | notSent(elementNotFound) |
| ax | shortcut | pass | **wrongWindow** | noEffect | **wrongWindow** | noEffect | pass | **wrongWindow** | noEffect | **wrongWindow** (cached) | noEffect (cached) | **wrongWindow** | noEffect |
