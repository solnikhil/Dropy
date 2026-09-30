# Dropy exact-window input probe

- Date: 2026-09-29 22:57 IST; revision: 3d37dae (uncommitted changes)
- macOS: 27.0 (26A428); hardware: Mac14,2
- Target: org.dropy.electronfixture chrome:150.0.7871.129 electron:43.2.0 window A; decoy: window B of the same app
- Desktop session: owner=input-probe-electron; input idle 63.0s at start; power 14
- tally noEffect=43 notApplicable=72 notSent=12 pass=40 wrongWindow=25

Cells: `pass` = effect in A only; **wrongWindow** = effect in B (fail); `noEffect` = nothing happened;
notes: front = frontmost app changed and was not restored, key = A's key state changed, desktop = active desktop changed, pointer = the pointer moved, cached = A reached through an element resolved earlier (verified by window ID); MODIFIER/BUTTON HELD = the trial left a modifier or mouse button down (released, trial failed).

| Route | Action | visible/aKey | visible/bKey | visible/appInactive | covered/bKey | covered/appInactive | parked/aKey | parked/bKey | parked/appInactive | otherSpace/bKey | otherSpace/appInactive | minimized/bKey | minimized/appInactive |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pidWindow | type | pass | **wrongWindow** | **wrongWindow** | **wrongWindow** | **wrongWindow** | pass | **wrongWindow** | **wrongWindow** | **wrongWindow** (cached) | **wrongWindow** (cached) | **wrongWindow** | **wrongWindow** |
| pidWindow | click | pass | noEffect (focus,key) | noEffect | noEffect (focus,key) | noEffect | pass | noEffect (focus,key) | noEffect | noEffect (focus,key,cached) | noEffect (cached) | noEffect | noEffect |
| pidWindow | scroll | pass | pass | pass | pass | pass | pass | pass | pass | noEffect (cached) | noEffect (cached) | noEffect | noEffect |
| pidWindow | shortcut | pass | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** | **wrongWindow(delivered)** | pass | **wrongWindow** | **wrongWindow(delivered)** | **wrongWindow** (cached) | **wrongWindow(delivered)** (cached) | **wrongWindow** | **wrongWindow(delivered)** |
| ax | type | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect (cached) | noEffect (cached) | noEffect | noEffect |
| ax | click | pass | pass | pass | pass | pass | pass | pass | pass | pass (cached) | pass (cached) | pass | pass |
| ax | scroll | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) | notSent(elementNotFound) (cached) | notSent(elementNotFound) (cached) | notSent(elementNotFound) | notSent(elementNotFound) |
| ax | shortcut | pass | **wrongWindow** | noEffect | **wrongWindow** | noEffect | pass | **wrongWindow** | noEffect | **wrongWindow** (cached) | noEffect (cached) | **wrongWindow** | noEffect |
| axValue | type | pass | pass | pass | pass | pass | pass | pass | pass | pass (cached) | pass (cached) | pass | pass |
| axValue | click | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) (cached) | notApplicable(textRouteOnly) (cached) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) |
| axValue | scroll | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) (cached) | notApplicable(textRouteOnly) (cached) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) |
| axValue | shortcut | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) (cached) | notApplicable(textRouteOnly) (cached) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) |
| axFocus | type | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect | noEffect (cached) | noEffect (cached) | noEffect | noEffect |
| axFocus | click | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) (cached) | notApplicable(textRouteOnly) (cached) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) |
| axFocus | scroll | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) (cached) | notApplicable(textRouteOnly) (cached) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) |
| axFocus | shortcut | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) (cached) | notApplicable(textRouteOnly) (cached) | notApplicable(textRouteOnly) | notApplicable(textRouteOnly) |
