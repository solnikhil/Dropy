import Foundation

/// The redraw schedule used after the compositor reports a drawable was never shown.
///
/// A drawable can be missed because the panel is still opening or is covered, and
/// because an idle layer's surface swap is not picked up (see `PresentationWarmth`).
/// Identical capture frames are skipped upstream, so the frame that was missed has to
/// ask for another drawable itself: nothing else will redraw it.
///
/// The first attempts also mark the view dirty so AppKit redraws at its next display
/// pass, which is the fast path; after that only the timed ladder remains and its delay
/// doubles to a cap, so a panel that stays covered stops spinning. These are the values
/// the 2026-09-30 trace was measured with, kept exactly so `PresentationMode.retry`
/// remains that baseline.
public struct PresentationRetryLadder: Equatable, Sendable {
    /// Delay before the first scheduled redraw: about one refresh at 60 Hz.
    public let firstDelayMilliseconds: Int
    /// The delay doubles up to this cap.
    public let capMilliseconds: Int
    /// How many attempts also mark the view dirty for AppKit's next display pass.
    public let immediateRedraws: Int
    private var scheduled = 0

    public init(firstDelayMilliseconds: Int = 16,
                capMilliseconds: Int = 1_000,
                immediateRedraws: Int = 3) {
        precondition(firstDelayMilliseconds > 0)
        precondition(capMilliseconds >= firstDelayMilliseconds && capMilliseconds <= Int.max / 2)
        precondition(immediateRedraws >= 0)
        self.firstDelayMilliseconds = firstDelayMilliseconds
        self.capMilliseconds = capMilliseconds
        self.immediateRedraws = immediateRedraws
    }

    /// The delay for the redraw at `index`, counting the first as zero. Pure, so the
    /// whole schedule can be asserted without driving a view.
    public func delayMilliseconds(forSchedule index: Int) -> Int {
        var delay = firstDelayMilliseconds
        var remaining = max(index, 0)
        // `delay` stays below the cap inside the loop and the cap is at most Int.max / 2,
        // so the doubling cannot overflow however large `index` is.
        while remaining > 0, delay < capMilliseconds {
            delay = min(delay * 2, capMilliseconds)
            remaining -= 1
        }
        return delay
    }

    /// True while `attempt` (the first is 1) should also mark the view dirty.
    public func redrawsImmediately(attempt: Int) -> Bool {
        attempt >= 1 && attempt <= immediateRedraws
    }

    /// How many redraws this ladder has scheduled since the last reset.
    public var scheduledCount: Int { scheduled }

    /// The next delay, advancing the ladder.
    public mutating func nextDelayMilliseconds() -> Int {
        defer { scheduled += 1 }
        return delayMilliseconds(forSchedule: scheduled)
    }

    /// A new frame starts the ladder again: its first redraw must be the fast one.
    public mutating func reset() { scheduled = 0 }
}
