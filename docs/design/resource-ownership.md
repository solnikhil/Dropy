# Resource ownership

Native registration lifetime follows the Swift owner. Weak callbacks avoid retaining a session, but do not unregister an observer, input monitor, event tap, or repeating timer from the system.

- `NotificationObservation` owns the center and its block-observer token. Cancellation is idempotent; destruction removes the registration from the same center that created it. A locked cancellation flag also suppresses deliveries queued before removal; a callback that already began may finish.
- `MainThreadCleanup` owns teardown for main-thread resources. Its action captures the native handles and callback context. An off-main final release queues teardown on the main thread and keeps the context alive until removal finishes.
- `EventMonitor`, `RepeatingTimer`, `EventTapRegistration`, and `AccessibilityObservation` use that cleanup owner. Clearing an optional or collection unregisters its resources; explicit stop and destruction use the same path.
- `GlobalHotKey` retains a callback receiver until both the key and handler have been removed. Failure paths release partial registrations exactly once and never register a key after handler installation fails.
- `AnimationFolderWatcher` lets FSEvents retain/release a callback context and owns stop/invalidate/release. The library cancels its pending scan when stopped, rejects callbacks while stopped, and can start again.

Callback closures should capture their session weakly. Cleanup actions capture the native resource and callback proxy, never their own cleanup owner. Do not pass an unowned session pointer to a long-lived system registration.

`Scripts/test-local.sh` checks notification-context release over 1,000 cycles, background final release, timer cancellation, hot-key success/failure teardown, run-loop-source removal, and real FSEvents stop/restart and context release. Input-hook creation and Accessibility subscriptions use controlled boundaries in these checks; no input is injected and no other app's live Accessibility events are subscribed to.
