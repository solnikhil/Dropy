import CoreGraphics
import Foundation

/// A damped spring as SwiftUI describes one: `response` is the period of the
/// undamped oscillation in seconds, `dampingRatio` 1 settles without overshoot and
/// lower values overshoot a little and come back.
public struct MorphSpring: Equatable, Sendable {
    public var response: TimeInterval
    public var dampingRatio: Double

    public init(response: TimeInterval, dampingRatio: Double) {
        self.response = response
        self.dampingRatio = dampingRatio
    }

    /// Progress from 0 to 1 at `time` seconds, starting at rest.
    public func value(at time: TimeInterval) -> Double {
        guard time > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        let zeta = dampingRatio
        if zeta >= 1 {
            return 1 - exp(-omega * time) * (1 + omega * time)
        }
        let damped = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * time)
        return 1 - decay * (cos(damped * time) + zeta * omega / damped * sin(damped * time))
    }

    /// When the spring stays within `tolerance` of its target from then on.
    public func settlingTime(tolerance: Double = 0.002) -> TimeInterval {
        let step = 1.0 / 240
        var settled: TimeInterval = 0
        var time: TimeInterval = 0
        while time < 3 {
            if abs(1 - value(at: time)) > tolerance { settled = time + step }
            time += step
        }
        return settled
    }
}

/// The overlay's outline as it moves between two shapes, frame by frame. Width and
/// height follow separate springs, as the system's own notch-attached motion does:
/// opening, the outline widens slightly ahead of dropping down; closing, it first
/// collapses to a pill and then narrows into the notch. One spring for the whole
/// shape looked like a rectangle being scaled.
public enum NotchMorph {
    public struct Motion: Equatable, Sendable {
        public var width: MorphSpring
        public var height: MorphSpring

        public init(width: MorphSpring, height: MorphSpring) {
            self.width = width
            self.height = height
        }

        public var duration: TimeInterval { max(width.settlingTime(), height.settlingTime()) }
    }

    /// Out of the notch: lively, with a small settle.
    public static let open = Motion(width: MorphSpring(response: 0.42, dampingRatio: 0.78),
                                    height: MorphSpring(response: 0.5, dampingRatio: 0.8))
    /// Back into the notch: quicker, no overshoot, height leading.
    public static let close = Motion(width: MorphSpring(response: 0.4, dampingRatio: 1),
                                     height: MorphSpring(response: 0.3, dampingRatio: 1))

    /// Between two open sizes, as when the window list gives way to the chosen
    /// window: settled, with barely any overshoot, since the overlay is already open.
    public static let resize = Motion(width: MorphSpring(response: 0.44, dampingRatio: 0.88),
                                      height: MorphSpring(response: 0.48, dampingRatio: 0.9))

    /// The frame on screen `elapsed` seconds into a morph: the nearest sample, or the
    /// end shape once it has settled. Lets an interrupting morph start from where the
    /// outline actually is instead of jumping to the previous target.
    public static func shape(in frames: [NotchShape], duration: TimeInterval, at elapsed: TimeInterval) -> NotchShape? {
        guard let last = frames.last else { return nil }
        guard duration > 0, elapsed < duration, frames.count > 1 else { return last }
        let index = Int((max(0, elapsed) / duration * Double(frames.count - 1)).rounded())
        return frames[min(index, frames.count - 1)]
    }

    /// The outline part way: width (and the ears) at `widthProgress`, height (and the
    /// lower corners) at `heightProgress`. It stays centered and hangs from the top
    /// edge; progress past 1 is the spring's overshoot.
    public static func shape(from start: NotchShape, to end: NotchShape,
                             widthProgress p: Double, heightProgress q: Double) -> NotchShape {
        func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
        let width = max(1, mix(start.body.width, end.body.width, p))
        let height = max(1, mix(start.body.height, end.body.height, q))
        let midX = mix(start.body.midX, end.body.midX, p)
        let top = start.body.maxY
        return NotchShape(body: CGRect(x: midX - width / 2, y: top - height, width: width, height: height),
                          bottomRadius: max(0, mix(start.bottomRadius, end.bottomRadius, q)),
                          earRadius: max(0, mix(start.earRadius, end.earRadius, p)))
    }

    /// Outlines sampled `framesPerSecond` times a second until both springs settle,
    /// ending exactly on `end`, with their times from 0 to 1.
    public static func frames(from start: NotchShape, to end: NotchShape, motion: Motion,
                              framesPerSecond: Double = 120) -> (shapes: [NotchShape], keyTimes: [Double], duration: TimeInterval) {
        let duration = motion.duration
        let count = max(2, Int((duration * framesPerSecond).rounded(.up)) + 1)
        var shapes: [NotchShape] = []
        var keyTimes: [Double] = []
        for index in 0..<count {
            let fraction = Double(index) / Double(count - 1)
            let time = fraction * duration
            shapes.append(index == count - 1 ? end : shape(from: start, to: end,
                                                           widthProgress: motion.width.value(at: time),
                                                           heightProgress: motion.height.value(at: time)))
            keyTimes.append(fraction)
        }
        return (shapes, keyTimes, duration)
    }

    /// Room around the open body for the opening overshoot, so the window edge never
    /// clips it.
    public static func overshootMargin(for size: CGSize) -> CGFloat {
        ceil(max(size.width, size.height) * 0.025) + NotchShape.openEarRadius
    }
}
