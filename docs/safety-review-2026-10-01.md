# Safety review of the interrupted implementation

Device checks remain paused. These changes were verified with local builds, core tests and isolated filesystem/session fixtures; they are not new compatibility evidence.

## Input authorization

- The router reads current source state and foreign-window coverage before every send. Any intersecting foreign window conservatively requires covered-condition evidence; Dropy's own overlay is excluded. Unknown Spaces, coverage or required window observations never become visible-condition evidence.
- Capture assigns a content revision to changed frames. The displayed revision must match the latest observed source revision, and the latest confirmation must be no more than 500 ms old. Identical and ScreenCaptureKit idle callbacks refresh confirmation without a main-thread hop or redraw. This confirmation lease is an input safety bound, not a relaxed performance budget.
- Typing uses the same preview confirmation and geometry gate as pointer input. Existing exact-element revalidation remains in place.
- Process-version, Accessibility-enablement and typing-target caches are pruned when preparing another source.

## Capture shutdown

Failed stops retain their stream and metrics and retry with bounded backoff. A new capture cannot accumulate behind an unconfirmed stop. The overlay reports that stopping is pending instead of silently remaining in its starting phase. The system's stop delegate is itself confirmation and settles retained state.

## Journal damage

Valid records in a partially damaged JSON array can be recovered independently. Before permitting removal of any such record, the entire original file is copied atomically and a persistent quarantine marker is written. Duplicate identities and invalid placement geometry are excluded. New placements remain blocked across relaunch until damaged records are resolved. Recovery alone can update an existing exact record before applying a restore; it cannot introduce another target. After applying a restore, the expected state must be observed before the entry is removed. Fully undecodable journals remain untouched and blocked. The recovery menu reports the preserved location.

The quarantine is intentionally not dismissed automatically. An unknown damaged record might describe a still-hidden window, so successful recovery of known records cannot establish that all recovery work is complete.

## Device sessions and disposable apps

- Unknown power or HID activity refuses a session. Production reads power from macOS, ignoring the old report override. Failed preference restoration keeps its backup but releases the kernel lock so the next owner can retry recovery.
- Filesystem hashing propagates traversal/read failures and includes empty directories and symlinks. Failed fingerprints cannot become apparently valid empty evidence.
- Installed identifiers are collected recursively, including nested helpers, system Applications and symlinked app bundles. Paths containing spaces remain intact.
- Shared app-script, group-container, ByHost, daemon and privileged-helper namespaces are observed. Known app paths are content-hashed; other namespace contents are not read, but their tree/file metadata is tracked. These observations remain conservative: unrelated namespace changes fail verification too.

## Remaining device evidence

The combined runtime still needs visible/parked input, static-source freshness, stop-error/revocation behavior, hand-off and region rendering checks once the pause is lifted. Existing compatibility and release gates are not promoted by these local tests.
