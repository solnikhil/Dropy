import Foundation

/// Tells whether a source's app slowed its rendering once Dropy hid the window.
///
/// Measured on 2026-09-30: with the window parked and no pixel of it visible, Safari
/// (animating page) fell from about 60 to 5 changed frames per second and QuickTime
/// (playing movie) to about 10; with a sliver visible both stayed near 60. Capture only
/// delivers changed frames, so a low rate alone cannot tell a throttled source from one
/// that simply stopped changing. The monitor therefore compares the rate just before
/// the window was hidden with the rate while hidden, and says nothing unless the source
/// was clearly animating before.
public struct HiddenSourceRateMonitor: Sendable {
    public enum Assessment: Equatable, Sendable {
        /// The source is not hidden by Dropy.
        case notHidden
        /// Not enough time or baseline to tell (e.g. the source was static before).
        case unknown
        /// The hidden rate is comparable to the rate before hiding.
        case normal
        /// The rate fell sharply when the window was hidden.
        case slowedWhileHidden(before: Double, hidden: Double)
    }

    /// Length (seconds) of the windows the two rates are measured over.
    public let window: TimeInterval
    /// A baseline below this (changed frames per second) is not animation.
    public let minimumBaseline: Double
    /// Hidden rate below this fraction of the baseline counts as slowed.
    public let slowedRatio: Double

    private var frames: [TimeInterval] = []
    private var hiddenAt: TimeInterval?
    private var baseline: Double?

    public init(window: TimeInterval = 2, minimumBaseline: Double = 20, slowedRatio: Double = 0.4) {
        precondition(window > 0 && minimumBaseline > 0 && slowedRatio > 0 && slowedRatio < 1)
        self.window = window
        self.minimumBaseline = minimumBaseline
        self.slowedRatio = slowedRatio
    }

    /// A frame that differed from the previous one arrived at `time` (seconds, monotonic).
    public mutating func recordChangedFrame(at time: TimeInterval) {
        guard time.isFinite, time >= (frames.last ?? -.infinity) else { return }
        frames.append(time)
        // Two windows cover both rates; older frames are never needed.
        let horizon = time - 2 * window
        if let first = frames.firstIndex(where: { $0 >= horizon }), first > 0 { frames.removeFirst(first) }
    }

    /// Dropy made the window fully hidden (parked with no visible sliver).
    public mutating func sourceHidden(at time: TimeInterval) {
        guard hiddenAt == nil else { return }
        hiddenAt = time
        let before = frames.filter { $0 >= time - window && $0 < time }.count
        // A capture that started less than a window ago has no honest baseline.
        baseline = (frames.first.map { $0 <= time - window * 0.9 } ?? false) ? Double(before) / window : nil
    }

    /// The window is visible again (restored, or a sliver uncovered).
    public mutating func sourceShown() {
        hiddenAt = nil
        baseline = nil
    }

    public func assessment(at now: TimeInterval) -> Assessment {
        guard let hiddenAt else { return .notHidden }
        guard let baseline, baseline >= minimumBaseline, now - hiddenAt >= window else { return .unknown }
        let hidden = Double(frames.filter { $0 > now - window && $0 <= now && $0 >= hiddenAt }.count) / window
        return hidden < baseline * slowedRatio ? .slowedWhileHidden(before: baseline, hidden: hidden) : .normal
    }

    /// The preview's wording; nil when there is nothing to say.
    public static func label(_ assessment: Assessment) -> String? {
        guard case .slowedWhileHidden(let before, let hidden) = assessment else { return nil }
        return "Hidden source slowed by its app · about \(Int(hidden.rounded())) fps (was \(Int(before.rounded())))"
    }
}
