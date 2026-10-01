# Completed coding handoff — 2026-10-01

Kiro was stopped before this continuation. Its saved sessions and original worktrees remain intact. Codex completed and integrated the six interrupted streams on `codex/finish-dropy-workstreams`.

| Stream | Implementation | Review history |
| --- | --- | --- |
| Hand-off typing | Explicit real-window hand-off, durable recovery and deferred start/end cancellation | #33 |
| Hidden source updates | Changed-frame monitoring, containment coverage, observed-rate label and lifecycle reset | #34 |
| Region and pins | GPU crop, per-app regions, view-only input policy, pinned picker and numeric selection | #35 |
| Latency | Successful-input capture wake and optional bounded presentation experiments | #32 |
| Release | Version/signing/notarization/rollback policy, verified ZIP/DMG rehearsal and tag workflow | #36 |
| Safety | Current-frame authorization, source coverage, stop retries, partial-journal recovery and stronger device isolation | Integrated directly |

The combined implementation reconciles shared AppKit/capture code, rather than assuming the separate streams compose. In particular, region and hand-off refusal survive the freshness gate; hand-off changes update containment; and recovery can update an existing valid journal record without permitting a new placement during quarantine. Restoration must be observed before its record is removed.

## Verification

- Native Swift 6 application build passes.
- All 198 core tests pass through the local XCTest runner.
- Native journal, overlay layout, frame outcome/clock and GPU region shader checks pass.
- Concurrent hidden-source monitoring passes under Thread Sanitizer.
- Isolated device-session and app-isolation fixtures pass. They do not drive the user's apps or desktop.
- Ad-hoc release packaging passes signature/Info.plist/entitlement verification, archive inspection, CLI checks and ZIP/DMG checksums. It neither launches Dropy nor uses distribution credentials.

## Still requires device or release evidence

Device checks remain paused. This continuation did not launch/capture personal apps or use synthetic input. The new runtime paths need device verification once the pause is lifted, including real-window hand-off, visible GPU cropping, stale/static input behavior, stop/revocation behavior and hidden-source reporting. Third-party compatibility, signing/notarization with actual distribution credentials, performance budgets and the update policy remain evidence gates. M3 and release readiness are not marked complete.

## Device testing resumed after this coding handoff

The user subsequently resumed testing. The [first integrated session](device-checks/2026-10-01-internal-alpha.md) records actual passes, the TextEdit covered-input failure, cleanup and still-unverified paths. The paused-device statements above describe the coding handoff, not the subsequent session. Milestone exits are unchanged.
