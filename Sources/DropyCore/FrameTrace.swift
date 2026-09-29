import Foundation

/// Where one captured frame's time went, from the moment ScreenCaptureKit says it was
/// displayed in the source to the moment the compositor put Dropy's drawable on glass
/// (M3/M4 latency trace, `DROPY_DEBUG_FRAME_TRACE=1`). All times are mach host
/// milliseconds; presentation is converted from Core Animation time with the stream's
/// measured clock offset before it is recorded here.
public struct FrameTrace: Equatable, Sendable {
    /// `SCStreamFrameInfo.displayTime`, when the stream supplied it.
    public var display: Double?
    /// The capture callback began.
    public var callback: Double
    /// The byte comparison with the previous forwarded frame finished.
    public var compared: Double?
    /// The frame was handed to the main thread (mailbox scheduled or replaced).
    public var forwarded: Double?
    /// The main thread took the frame from the mailbox.
    public var delivered: Double?
    /// Each draw that encoded this frame, and its outcome: the presentation time, or nil
    /// when the compositor reported the drawable as never shown (a drawable miss).
    public var draws: [Draw] = []
    /// The most recent input Dropy sent to the source before this frame's callback.
    public var input: Double?

    public struct Draw: Equatable, Sendable {
        public var committed: Double
        public var presented: Double?
        public init(committed: Double, presented: Double?) {
            self.committed = committed
            self.presented = presented
        }
    }

    public init(display: Double?, callback: Double) {
        self.display = display
        self.callback = callback
    }

    /// The final on-glass time, if any draw was shown.
    public var presented: Double? { draws.last(where: { $0.presented != nil })?.presented }

    /// Consecutive stage durations in milliseconds. Missing stages are omitted.
    /// `draw` runs from delivery to the commit of the draw that was finally shown, so
    /// drawable misses and their retries land there; `compose` is commit to on-glass.
    public var stages: [(name: String, milliseconds: Double)] {
        var result: [(String, Double)] = []
        if let display { result.append(("capture", callback - display)) }
        if let compared { result.append(("compare", compared - callback)) }
        if let compared, let forwarded { result.append(("forward", forwarded - compared)) }
        if let forwarded, let delivered { result.append(("main", delivered - forwarded)) }
        if let delivered, let shown = draws.last(where: { $0.presented != nil }) {
            result.append(("draw", shown.committed - delivered))
            result.append(("compose", shown.presented! - shown.committed))
        }
        return result
    }

    /// Drawables encoded for this frame that were never shown.
    public var misses: Int { draws.filter { $0.presented == nil }.count }

    /// One log-safe line: stage durations, attempts, and ages relative to input.
    public var logLine: String {
        var parts = stages.map { String(format: "%@=%.1f", $0.name, $0.milliseconds) }
        parts.append("draws=\(draws.count)")
        parts.append("misses=\(misses)")
        if let display, let presented { parts.append(String(format: "age=%.1f", presented - display)) }
        if let input {
            parts.append(String(format: "input=%.1f", input))
            if let display { parts.append(String(format: "inputToDisplay=%.1f", display - input)) }
            if let presented { parts.append(String(format: "inputToPresent=%.1f", presented - input)) }
        }
        if presented == nil { parts.append("outcome=notPresented") }
        return parts.joined(separator: " ")
    }
}
