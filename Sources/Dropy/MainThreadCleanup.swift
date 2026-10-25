import Foundation

/// Owns a native registration's teardown and callback context. Explicit shutdown
/// releases this owner; destruction is the fallback. If the last reference goes
/// away off the main thread, the context stays alive until main-thread cleanup.
final class MainThreadCleanup: Sendable {
    private let action: @MainActor @Sendable () -> Void

    init(_ action: @escaping @MainActor @Sendable () -> Void) { self.action = action }

    deinit {
        let action = action
        if Thread.isMainThread {
            MainActor.assumeIsolated { action() }
        } else {
            DispatchQueue.main.async { action() }
        }
    }
}
