import DropyCore
import Foundation

/// One stream's `HiddenSourceRateMonitor`, shared by the capture queue and the main
/// actor: changed-frame times are recorded where the frames arrive, while the
/// concealment changes and the assessment are read on the main actor.
///
/// Per changed frame this costs one uncontended lock and one array append, and no
/// main-thread work at all. A stream owns its monitor, so switching source or stopping
/// capture drops it: the next stream starts without a baseline instead of inheriting
/// another window's history.
final class HiddenSourceRate: @unchecked Sendable {
    private let lock = NSLock()
    private var monitor: HiddenSourceRateMonitor

    init(monitor: HiddenSourceRateMonitor = HiddenSourceRateMonitor()) {
        self.monitor = monitor
    }

    /// The clock every time the monitor is given comes from: the monotonic mach clock,
    /// the same one frame callbacks are stamped on. This is the only place in the app
    /// that reads it for the monitor, so no call site can pick a different one — and a
    /// mixed epoch would not fail loudly, it would leave the monitor permanently
    /// `.unknown`. `HiddenSourceRateMonitor.clocksAgree` is the assertable form of the
    /// contract; Tests/LocalHiddenSourceRateCheck.swift holds it to this clock and
    /// Tests/LocalFrameStampCheck.swift holds the frame stamps to it.
    static func now() -> TimeInterval { HostClock.nowSeconds() }

    /// A frame that differed from the previous one arrived. `time` is seconds on the
    /// monotonic mach clock; callers pass the frame's own callback time, so no clock is
    /// read per frame.
    func recordFrame(changed: Bool, at time: TimeInterval) {
        guard changed else { return }
        lock.withLock { monitor.recordChangedFrame(at: time) }
    }

    /// Dropy's containment now hides every pixel of the source, or no longer does.
    /// `time` defaults to `now()`; tests inject one.
    func setHidden(_ hidden: Bool, at time: TimeInterval = HiddenSourceRate.now()) {
        lock.withLock {
            if hidden { monitor.sourceHidden(at: time) } else { monitor.sourceShown() }
        }
    }

    /// What the rates say. `time` defaults to `now()`; tests inject one.
    func assessment(at time: TimeInterval = HiddenSourceRate.now()) -> HiddenSourceRateMonitor.Assessment {
        lock.withLock { monitor.assessment(at: time) }
    }
}
