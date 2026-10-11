import CoreGraphics
import Foundation
import os

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

    /// When the spring stays within `tolerance` of its target from then on. Remembered
    /// per spring: the Studio's graph and every morph ask many times a frame.
    public func settlingTime(tolerance: Double = 0.002) -> TimeInterval {
        let key = SettlingKey(response: response, damping: dampingRatio, tolerance: tolerance)
        if let known = Self.settling.withLock({ $0[key] }) { return known }
        let time = computeSettlingTime(tolerance: tolerance)
        Self.settling.withLock { cache in
            if cache.count > 512 { cache.removeAll() }
            cache[key] = time
        }
        return time
    }

    private struct SettlingKey: Hashable {
        let response: Double
        let damping: Double
        let tolerance: Double
    }

    private static let settling = OSAllocatedUnfairLock(initialState: [SettlingKey: TimeInterval]())

    private func computeSettlingTime(tolerance: Double) -> TimeInterval {
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
        /// The width and the ears where the outline meets the screen edge.
        public var width: MotionCurve
        /// The height and the lower corners.
        public var height: MotionCurve
        /// Progress only moves forward and never past the end. Set for closing: once
        /// the outline has gone into the notch it can never spring back out of the
        /// camera housing, whatever curve an animation gives it.
        public var isMonotonic: Bool

        public init(width: MorphSpring, height: MorphSpring) {
            self.init(width: .spring(width), height: .spring(height))
        }

        public init(width: MotionCurve, height: MotionCurve, isMonotonic: Bool = false) {
            self.width = width
            self.height = height
            self.isMonotonic = isMonotonic
        }

        public var duration: TimeInterval { max(width.duration, height.duration) }

        /// How far past its end (above 1) or back past its start (below 0) the outline
        /// travels, as played.
        public var extent: ClosedRange<Double> {
            if isMonotonic { return 0...1 }
            let width = width.extent
            let height = height.extent
            return min(width.lowerBound, height.lowerBound)...max(width.upperBound, height.upperBound)
        }

        /// Progress of each part at `time`, as played (forward only when monotonic).
        func progress(at time: TimeInterval, after previous: (width: Double, height: Double)?) -> (width: Double, height: Double) {
            let width = width.value(at: time)
            let height = height.value(at: time)
            guard isMonotonic else { return (width, height) }
            return (max(min(width, 1), previous?.width ?? 0), max(min(height, 1), previous?.height ?? 0))
        }
    }

    /// The default style's springs. Each `MotionStyle` has its own set.
    public static var open: Motion { MotionStyle.balanced.morph.open }
    public static var close: Motion { MotionStyle.balanced.morph.close }
    public static var resize: Motion { MotionStyle.balanced.morph.resize }

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
    /// lower corners) at `heightProgress`. It stays centered and attached to the
    /// screen edge it grows from (at the notch it hangs from the top edge); progress
    /// past 1 is the spring's overshoot. At a side edge "width" is the length along
    /// the edge and "height" how far the outline reaches into the screen; in a corner
    /// they are the horizontal and vertical size, with the corner fixed.
    public static func shape(from start: NotchShape, to end: NotchShape,
                             widthProgress p: Double, heightProgress q: Double) -> NotchShape {
        func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
        let s = start.body, e = end.body
        let body: CGRect
        switch end.position {
        case .notch:
            let width = max(1, mix(s.width, e.width, p))
            let height = max(1, mix(s.height, e.height, q))
            let midX = mix(s.midX, e.midX, p)
            body = CGRect(x: midX - width / 2, y: s.maxY - height, width: width, height: height)
        case .left, .right:
            let along = max(1, mix(s.height, e.height, p))
            let depth = max(1, mix(s.width, e.width, q))
            let midY = mix(s.midY, e.midY, p)
            let x = end.position == .left ? s.minX : s.maxX - depth
            body = CGRect(x: x, y: midY - along / 2, width: depth, height: along)
        case .bottomLeft, .bottomRight:
            let width = max(1, mix(s.width, e.width, p))
            let height = max(1, mix(s.height, e.height, q))
            let x = end.position == .bottomLeft ? s.minX : s.maxX - width
            body = CGRect(x: x, y: s.minY, width: width, height: height)
        }
        return NotchShape(body: body,
                          bottomRadius: max(0, mix(start.bottomRadius, end.bottomRadius, q)),
                          earRadius: max(0, mix(start.earRadius, end.earRadius, p)),
                          position: end.position)
    }

    /// Outlines sampled `framesPerSecond` times a second until both springs settle,
    /// ending exactly on `end`, with their times from 0 to 1.
    public static func frames(from start: NotchShape, to end: NotchShape, motion: Motion,
                              framesPerSecond: Double = 120) -> (shapes: [NotchShape], keyTimes: [Double], duration: TimeInterval) {
        let duration = motion.duration
        let count = max(2, Int((duration * framesPerSecond).rounded(.up)) + 1)
        var shapes: [NotchShape] = []
        var keyTimes: [Double] = []
        var previous: (width: Double, height: Double)?
        for index in 0..<count {
            let fraction = Double(index) / Double(count - 1)
            let time = fraction * duration
            let progress = motion.progress(at: time, after: previous)
            previous = progress
            shapes.append(index == count - 1 ? end : shape(from: start, to: end,
                                                           widthProgress: progress.width,
                                                           heightProgress: progress.height))
            keyTimes.append(fraction)
        }
        return (shapes, keyTimes, duration)
    }

    /// Room around the open body for the outline's overshoot, so the window edge never
    /// clips it. `reach` is how far past its target (as a fraction of the size) the
    /// animation in use ever takes the outline; the built-in styles stay within 2.5 %.
    public static func overshootMargin(for size: CGSize, reach: Double = defaultReach) -> CGFloat {
        ceil(max(size.width, size.height) * max(reach, defaultReach)) + NotchShape.openEarRadius
    }

    public static let defaultReach = 0.025
}
