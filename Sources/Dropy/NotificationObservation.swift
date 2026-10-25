import Foundation

/// Owns one block observation together with the center that registered it.
/// Removing an owner (or replacing its token) must also remove the center's copy
/// of the callback; weak captures alone do not unregister block observers.
///
/// The opaque token never escapes. NotificationCenter supports registration and
/// removal across threads. The cancellation flag is locked, so this owner may
/// also be cancelled or released anywhere.
final class NotificationObservation: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return active
        }
        func cancel() {
            lock.lock()
            active = false
            lock.unlock()
        }
    }

    private let center: NotificationCenter
    private let token: NSObjectProtocol
    private let state: State

    init(center: NotificationCenter = .default, forName name: Notification.Name,
         object: Any? = nil, queue: OperationQueue? = .main,
         using block: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        let state = State()
        self.state = state
        token = center.addObserver(forName: name, object: object, queue: queue) { notification in
            // Removal does not retract a delivery already queued by the center.
            guard state.isActive else { return }
            block(notification)
        }
    }

    /// NotificationCenter permits repeated removal. Keep this safe to call before
    /// destruction, too, so explicit shutdown and automatic cleanup compose.
    func cancel() {
        state.cancel()
        center.removeObserver(token)
    }

    deinit { cancel() }
}
