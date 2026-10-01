import Foundation

/// Confirms that the displayed content is still the latest observed source content.
/// Idle/identical callbacks refresh the lease without a draw or main-thread hop.
public final class CaptureConfirmation: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var observedAt: Double?
    private var valid = true
    public static let maximumAgeMilliseconds = 500.0

    public init() {}

    @discardableResult
    public func observe(changed: Bool, at milliseconds: Double) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard valid, milliseconds.isFinite else { return nil }
        if changed { revision &+= 1 }
        guard revision != 0 else { return nil }
        observedAt = milliseconds
        return revision
    }

    public func permits(revision displayed: UInt64?, at milliseconds: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard valid, let displayed, displayed == revision, let observedAt,
              milliseconds.isFinite, milliseconds >= observedAt else { return false }
        return milliseconds - observedAt <= Self.maximumAgeMilliseconds
    }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        valid = false
        observedAt = nil
    }
}
