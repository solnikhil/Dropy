/// Content-driven capture rate with hysteresis. A single configuration-induced
/// changed frame is delivered normally but cannot cause idle/full-rate oscillation.
public struct CaptureActivityTracker: Sendable {
    public static let defaultUnchangedThreshold = 30
    public private(set) var isIdle = false
    private var unchangedCount = 0
    private var changedCount = 0
    private let unchangedThreshold: Int
    private let changedThreshold: Int

    public init(unchangedThreshold: Int = defaultUnchangedThreshold, changedThreshold: Int = 2) {
        precondition(unchangedThreshold > 0 && changedThreshold > 0)
        self.unchangedThreshold = unchangedThreshold
        self.changedThreshold = changedThreshold
    }

    /// Returns the new rate state only on a transition. Changed frames must always
    /// be rendered, independent of this rate decision. At idle 10 fps, two changes
    /// resume 60 fps within two sampling intervals; a static update stays at 10 fps.
    public mutating func record(unchanged: Bool) -> Bool? {
        if unchanged {
            changedCount = 0
            if unchangedCount < unchangedThreshold { unchangedCount += 1 }
            if !isIdle && unchangedCount == unchangedThreshold {
                isIdle = true
                return true
            }
        } else {
            unchangedCount = 0
            if changedCount < changedThreshold { changedCount += 1 }
            if isIdle && changedCount == changedThreshold {
                isIdle = false
                return false
            }
        }
        return nil
    }
}
