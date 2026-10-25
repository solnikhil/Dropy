import Foundation

/// Run loops retain scheduled timers. Keep cancellation tied to the owner's
/// lifetime, rather than leaving a repeating weak-self callback running forever.
@MainActor
final class RepeatingTimer {
    private let cleanup: MainThreadCleanup

    init(interval: TimeInterval, tolerance: TimeInterval = 0, mode: RunLoop.Mode = .default,
         action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = tolerance
        cleanup = MainThreadCleanup { timer.invalidate() }
        RunLoop.main.add(timer, forMode: mode)
    }
}
