import CoreGraphics
import Foundation

/// How the overlay moves. Every style keeps the same choreography (the outline widens
/// a little ahead of dropping down, the content comes into focus as it grows, and
/// closing collapses height before width without overshooting); they differ in tempo
/// and in how much the springs settle.
public enum MotionStyle: String, Codable, CaseIterable, Sendable {
    /// Quick and direct: short, critically damped springs and a plain fade, for
    /// people who open the overlay many times an hour.
    case rapid
    /// Smooth but quick: a light settle and a short focus pull. Fast enough for
    /// everyday use, soft enough not to feel abrupt.
    case balanced
    /// Unhurried and satisfying: longer springs with a visible settle, and content
    /// that drifts into focus.
    case smooth

    public var title: String {
        switch self {
        case .rapid: "Rapid"
        case .balanced: "Balanced"
        case .smooth: "Smooth"
        }
    }

    /// The outline's springs.
    public var morph: NotchMorph.Motions {
        switch self {
        case .rapid:
            NotchMorph.Motions(
                open: .init(width: MorphSpring(response: 0.24, dampingRatio: 0.92),
                            height: MorphSpring(response: 0.27, dampingRatio: 0.94)),
                close: .init(width: MorphSpring(response: 0.22, dampingRatio: 1),
                             height: MorphSpring(response: 0.16, dampingRatio: 1)),
                resize: .init(width: MorphSpring(response: 0.24, dampingRatio: 0.95),
                              height: MorphSpring(response: 0.26, dampingRatio: 0.96)))
        case .balanced:
            NotchMorph.Motions(
                open: .init(width: MorphSpring(response: 0.34, dampingRatio: 0.82),
                            height: MorphSpring(response: 0.38, dampingRatio: 0.84)),
                close: .init(width: MorphSpring(response: 0.32, dampingRatio: 1),
                             height: MorphSpring(response: 0.24, dampingRatio: 1)),
                resize: .init(width: MorphSpring(response: 0.34, dampingRatio: 0.9),
                              height: MorphSpring(response: 0.38, dampingRatio: 0.9)))
        case .smooth:
            NotchMorph.Motions(
                open: .init(width: MorphSpring(response: 0.52, dampingRatio: 0.76),
                            height: MorphSpring(response: 0.6, dampingRatio: 0.78)),
                close: .init(width: MorphSpring(response: 0.46, dampingRatio: 1),
                             height: MorphSpring(response: 0.36, dampingRatio: 1)),
                resize: .init(width: MorphSpring(response: 0.5, dampingRatio: 0.86),
                              height: MorphSpring(response: 0.55, dampingRatio: 0.87)))
        }
    }

    /// How the content inside the outline arrives and leaves.
    public var content: ContentMotion {
        switch self {
        case .rapid:
            ContentMotion(revealDelay: 0.02, revealDuration: 0.16, hideDuration: 0.08, relayoutDuration: 0.14,
                          staggerSpan: 0.03, staggerDrift: 4, restScale: 0.97, blurRadius: 0)
        case .balanced:
            ContentMotion(revealDelay: 0.05, revealDuration: 0.26, hideDuration: 0.12, relayoutDuration: 0.2,
                          staggerSpan: 0.07, staggerDrift: 8, restScale: 0.93, blurRadius: 10)
        case .smooth:
            ContentMotion(revealDelay: 0.08, revealDuration: 0.42, hideDuration: 0.18, relayoutDuration: 0.3,
                          staggerSpan: 0.12, staggerDrift: 12, restScale: 0.88, blurRadius: 16)
        }
    }
}

/// Timings for the content inside the outline.
public struct ContentMotion: Equatable, Sendable {
    /// The content starts once the outline has visibly begun to grow.
    public var revealDelay: TimeInterval
    public var revealDuration: TimeInterval
    public var hideDuration: TimeInterval
    /// A new layout fading up inside a resizing outline.
    public var relayoutDuration: TimeInterval
    /// Lower content arrives up to this much later, so it reads as falling out of the notch.
    public var staggerSpan: TimeInterval
    /// Each piece drifts down into place from this far above.
    public var staggerDrift: CGFloat
    /// Size relative to final at the start of a reveal and the end of a hide.
    public var restScale: CGFloat
    /// Out of focus at the start of a reveal; 0 means no blur (cheaper, crisper).
    public var blurRadius: CGFloat
    /// The timing of a reveal's scale, focus and drift.
    public var revealCurve: TimingCurve
    /// The timing of a hide.
    public var hideCurve: TimingCurve

    public init(revealDelay: TimeInterval, revealDuration: TimeInterval, hideDuration: TimeInterval,
                relayoutDuration: TimeInterval, staggerSpan: TimeInterval, staggerDrift: CGFloat,
                restScale: CGFloat, blurRadius: CGFloat,
                revealCurve: TimingCurve = .settle, hideCurve: TimingCurve = .leave) {
        self.revealDelay = revealDelay
        self.revealDuration = revealDuration
        self.hideDuration = hideDuration
        self.relayoutDuration = relayoutDuration
        self.staggerSpan = staggerSpan
        self.staggerDrift = staggerDrift
        self.restScale = restScale
        self.blurRadius = blurRadius
        self.revealCurve = revealCurve
        self.hideCurve = hideCurve
    }

    /// The content's opacity `time` seconds into a reveal, with the stagger's last
    /// piece arriving `staggerSpan` later (an approximation for drawings and previews).
    public func revealOpacity(at time: TimeInterval) -> Double {
        let fade = revealDuration * 0.8
        guard fade > 0 else { return time >= revealDelay ? 1 : 0 }
        let s = (time - revealDelay) / fade
        return TimingCurve.easeOut.value(at: min(max(s, 0), 1))
    }
}

extension NotchMorph {
    /// The outline's springs for one style.
    public struct Motions: Equatable, Sendable {
        /// Out of the notch.
        public var open: Motion
        /// Back into the notch: never overshoots, so it cannot poke out of the housing.
        public var close: Motion
        /// Between two open sizes, as when the window list gives way to the chosen window.
        public var resize: Motion

        public init(open: Motion, close: Motion, resize: Motion) {
            self.open = open
            var close = close
            close.isMonotonic = true
            self.close = close
            self.resize = resize
        }

        /// How far past its target the outline ever goes while opening or resizing, as
        /// a fraction of the overlay's size: the window's margin must hold it.
        public var reach: Double {
            let open = open.extent
            let resize = resize.extent
            return max(open.upperBound - 1, resize.upperBound - 1, -resize.lowerBound, 0)
        }
    }
}
