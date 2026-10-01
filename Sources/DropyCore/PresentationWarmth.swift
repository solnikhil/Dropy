import Foundation

/// Decides when the preview should keep its display link running (`PresentationMode.warm`).
///
/// **Hypothesis, not yet measured.** The 2026-09-30 trace shows that while the source
/// keeps changing, every drawable is shown; after a quiet period the first drawables are
/// reported never shown, as many of them as the layer pools. With `presentsWithTransaction`
/// off, `MTLCommandBuffer.present` schedules a surface swap that only reaches the screen
/// if the layer is composited in that pass, and a layer that has presented nothing for
/// seconds does not get one for the swap it just scheduled. Driving the display link for
/// a short window should hold the layer in the state the trace measures no misses in.
///
/// Warmth is always bounded and always expires, so a quiet or closed preview returns to
/// doing no periodic work. That matters for two budgets in docs/BENCHMARK.md: CPU when
/// the source is unchanged (≤ 2%) and CPU with the overlay closed (≈ 0%).
public struct PresentationWarmth: Equatable, Sendable {
    /// How long warmth lasts after each stimulus, in seconds.
    public struct Windows: Equatable, Sendable {
        /// Dropy sent input to the source. Input to captured frame measured 64–75 ms at
        /// p50 (the app's handling plus up to one 10 fps idle capture interval), and the
        /// frame then needs a draw and a compose, so this window has to outlast all of it.
        public var afterInput: TimeInterval
        /// A frame arrived after a quiet gap, so this frame itself met a cold path. It
        /// covers sources that change without Dropy having sent anything.
        public var afterColdFrame: TimeInterval
        /// The compositor reported a drawable was never shown: direct evidence the path
        /// is cold, and the redraw that follows needs to land on a warm one.
        public var afterMiss: TimeInterval

        public init(afterInput: TimeInterval = 0.35,
                    afterColdFrame: TimeInterval = 0.2,
                    afterMiss: TimeInterval = 0.25) {
            precondition(afterInput >= 0 && afterColdFrame >= 0 && afterMiss >= 0)
            self.afterInput = afterInput
            self.afterColdFrame = afterColdFrame
            self.afterMiss = afterMiss
        }
    }

    public let windows: Windows
    /// A frame drawn at least this long after the previous one counts as following a
    /// quiet gap. The idle capture rate is 10 fps, so an active source's changed frames
    /// arrive closer together than this and are not mistaken for a wake.
    public let coldGap: TimeInterval
    /// The time warmth expires, or nil when the path is cold.
    public private(set) var warmUntil: TimeInterval?
    private var lastFrame: TimeInterval?

    public init(windows: Windows = Windows(), coldGap: TimeInterval = 0.25) {
        precondition(coldGap > 0)
        self.windows = windows
        self.coldGap = coldGap
    }

    /// Dropy sent input to the source; a changed frame is expected shortly.
    public mutating func noteInput(at time: TimeInterval) {
        extend(to: time + windows.afterInput)
    }

    /// A captured frame is about to be drawn. Returns true when it follows a quiet gap,
    /// which is the cold case the trace measures drawable misses on. Display-link redraws
    /// are not frames and must not be reported here, or a warm period would keep
    /// restating that the path is warm and hide the next real gap.
    @discardableResult
    public mutating func noteFrame(at time: TimeInterval) -> Bool {
        // A clock that went backwards says nothing about the path; ignore the report
        // rather than letting a negative gap read as warm.
        if let lastFrame, time < lastFrame { return false }
        // The first frame of a session has no predecessor and finds the coldest path
        // of all: the cold reveal.
        let cold = lastFrame.map { time - $0 >= coldGap } ?? true
        lastFrame = time
        if cold { extend(to: time + windows.afterColdFrame) }
        return cold
    }

    /// The compositor reported a drawable was never shown.
    public mutating func noteDrawableMiss(at time: TimeInterval) {
        extend(to: time + windows.afterMiss)
    }

    /// Nothing is on screen any more: the preview was cleared, or the overlay closed.
    /// Warmth ends at once rather than expiring, so closing cannot leave work running.
    public mutating func cool() {
        warmUntil = nil
        lastFrame = nil
    }

    public func isWarm(at time: TimeInterval) -> Bool {
        guard let warmUntil else { return false }
        return time < warmUntil
    }

    /// Seconds of warmth left, or nil when it is already cold. The caller schedules its
    /// cool-down from this, so it never has to guess which stimulus set the deadline.
    public func remaining(at time: TimeInterval) -> TimeInterval? {
        guard let warmUntil, time < warmUntil else { return nil }
        return warmUntil - time
    }

    private mutating func extend(to deadline: TimeInterval) {
        guard deadline.isFinite else { return }
        warmUntil = max(warmUntil ?? deadline, deadline)
    }
}
