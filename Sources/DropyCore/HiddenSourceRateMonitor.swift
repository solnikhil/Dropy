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

        /// A log-safe name: rates only, no app name, window title or content.
        public var diagnosticName: String {
            switch self {
            case .notHidden: "notHidden"
            case .unknown: "unknown"
            case .normal: "normal"
            case .slowedWhileHidden(let before, let hidden):
                "slowed(before=\(Int(before.rounded())),hidden=\(Int(hidden.rounded())))"
            }
        }
    }

    /// Length (seconds) of the windows the two rates are measured over.
    public let window: TimeInterval
    /// A baseline below this (changed frames per second) is not animation.
    public let minimumBaseline: Double
    /// Hidden rate below this fraction of the baseline counts as slowed.
    public let slowedRatio: Double

    /// Changed-frame times, oldest first. `oldest` is the index of the first one still
    /// wanted: dropping a frame moves that index instead of shifting the array.
    private var frames: [TimeInterval] = []
    private var oldest = 0
    private var hiddenAt: TimeInterval?
    private var baseline: Double?

    /// The frames still inside the two measuring windows.
    private var kept: ArraySlice<TimeInterval> { frames[oldest...] }

    /// How many frame times the monitor is holding, including the ones it has dropped
    /// but not yet compacted away. Exposed because unbounded growth here would be
    /// invisible in every short test and only show up in a capture left running for
    /// hours: `HiddenSourceRateMonitorTests` holds this to the two windows' worth the
    /// monitor is allowed instead of trusting the pruning to a comment.
    public var heldFrameCount: Int { frames.count }

    public init(window: TimeInterval = 2, minimumBaseline: Double = 20, slowedRatio: Double = 0.4) {
        precondition(window > 0 && minimumBaseline > 0 && slowedRatio > 0 && slowedRatio < 1)
        self.window = window
        self.minimumBaseline = minimumBaseline
        self.slowedRatio = slowedRatio
    }

    /// A frame that differed from the previous one arrived at `time` (seconds, monotonic).
    ///
    /// This runs on the capture queue for every frame the source draws, so it is written
    /// to cost the same at the tenth frame and the ten-thousandth: an append, and an
    /// index move for each frame that fell out of the windows. The array is compacted
    /// only once at least half of it is dead, which amortises to a constant per frame —
    /// where `removeFirst` per frame shifted the whole buffer every time.
    public mutating func recordChangedFrame(at time: TimeInterval) {
        guard time.isFinite, time >= (frames.last ?? -.infinity) else { return }
        frames.append(time)
        // Two windows cover both rates; older frames are never needed.
        let horizon = time - 2 * window
        while oldest < frames.count, frames[oldest] < horizon { oldest += 1 }
        if oldest * 2 >= frames.count {
            frames.removeFirst(oldest)
            oldest = 0
        }
    }

    /// Dropy made the window fully hidden (parked with no visible sliver). `time` is on
    /// the same monotonic clock as the frames; see `clocksAgree`.
    public mutating func sourceHidden(at time: TimeInterval) {
        guard hiddenAt == nil, time.isFinite else { return }
        hiddenAt = time
        let before = kept.count { $0 >= time - window && $0 < time }
        // A capture that started less than a window ago has no honest baseline.
        baseline = (kept.first.map { $0 <= time - window * 0.9 } ?? false) ? Double(before) / window : nil
    }

    /// The window is visible again (restored, or a sliver uncovered).
    public mutating func sourceShown() {
        hiddenAt = nil
        baseline = nil
    }

    /// What the rates say now. `now` is on the same monotonic clock as the frames and
    /// the hidden moment; see `clocksAgree`.
    public func assessment(at now: TimeInterval) -> Assessment {
        guard let hiddenAt else { return .notHidden }
        guard now.isFinite else { return .unknown }
        guard let baseline, baseline >= minimumBaseline, now - hiddenAt >= window else { return .unknown }
        let hidden = Double(kept.count { $0 > now - window && $0 <= now && $0 >= hiddenAt }) / window
        return hidden < baseline * slowedRatio ? .slowedWhileHidden(before: baseline, hidden: hidden) : .normal
    }

    /// Whether two readings taken in immediate succession come from one clock.
    ///
    /// The monitor only ever compares its times with each other, so all three kinds —
    /// the frames, the moment the window became hidden, and the moment a verdict is
    /// asked for — must be read from one monotonic epoch. Mixing epochs fails silently
    /// rather than loudly: a wall-clock hidden moment against mach-clock frames leaves
    /// every measuring window empty, so the monitor answers `.unknown` forever and the
    /// preview simply never says anything. The callers therefore keep one clock owner
    /// and the local checks assert this predicate over it.
    ///
    /// A clock that produced no reading is rejected without a test for it: every
    /// comparison against a NaN difference is false, and infinity less infinity is NaN.
    ///
    /// - Parameter tolerance: the largest gap two readings taken one after the other may
    ///   show. The epochs Dropy could confuse (seconds since boot against seconds since
    ///   1970) lie decades apart, so any value that admits the work between two reads
    ///   separates them.
    public static func clocksAgree(_ first: TimeInterval, _ second: TimeInterval,
                                   tolerance: TimeInterval = 0.05) -> Bool {
        abs(first - second) <= tolerance
    }

    /// The preview's wording; nil when there is nothing to say.
    public static func label(_ assessment: Assessment) -> String? {
        guard case .slowedWhileHidden(let before, let hidden) = assessment else { return nil }
        return "Hidden updates: \(Int(hidden.rounded())) fps (was \(Int(before.rounded())))"
    }
}
