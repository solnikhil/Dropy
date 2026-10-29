import CoreGraphics
import Foundation

/// How one part of the overlay's outline gets from where a motion starts (0) to where
/// it ends (1) over time. The width part moves the width and the ears where the outline
/// meets the screen edge; the height part moves the height and the lower corners
/// (`NotchMorph.shape`). Values past 1 overshoot the end; values below 0 pull back past
/// the start.
public enum MotionCurve: Equatable, Sendable {
    /// A physical spring that starts after `delay` seconds.
    case spring(MorphSpring, delay: TimeInterval = 0)
    /// Placed (or drawn) points in time, each reached along its own ease.
    case keyframes([MotionKeyframe])

    /// Progress at `time` seconds into the motion.
    public func value(at time: TimeInterval) -> Double {
        switch self {
        case .spring(let spring, let delay): spring.value(at: time - delay)
        case .keyframes(let keys): MotionKeyframe.value(of: keys, at: time)
        }
    }

    /// When the curve reaches its end and stays there.
    public var duration: TimeInterval {
        switch self {
        case .spring(let spring, let delay): delay + spring.settlingTime()
        case .keyframes(let keys): keys.last?.time ?? 0
        }
    }

    /// The highest and lowest progress the curve passes through (always including 0
    /// and 1, where every motion starts and ends).
    public var extent: ClosedRange<Double> {
        var low = 0.0
        var high = 1.0
        let end = duration
        var time = 0.0
        while time <= end {
            let value = value(at: time)
            low = min(low, value)
            high = max(high, value)
            time += 1.0 / 240
        }
        if case .keyframes(let keys) = self {
            for key in keys {
                low = min(low, key.value)
                high = max(high, key.value)
            }
        }
        return low...high
    }

    /// The same curve played `factor` times as long.
    public func stretched(by factor: Double) -> MotionCurve {
        switch self {
        case .spring(let spring, let delay):
            .spring(MorphSpring(response: spring.response * factor, dampingRatio: spring.dampingRatio), delay: delay * factor)
        case .keyframes(let keys):
            .keyframes(keys.map { MotionKeyframe(time: $0.time * factor, value: $0.value, ease: $0.ease) })
        }
    }

    /// This curve played backwards, as keyframes: an opening turned into the matching
    /// closing. Where the original waited at its start, the reverse ends as soon as it
    /// arrives instead of holding.
    public func reversed() -> MotionCurve {
        if case .keyframes(var keys) = self, keys.count >= 2 {
            // Remove only the opening's initial hold. A later return to zero (or
            // below it) is part of the motion, not the end of the reverse.
            while keys.count > 2 && keys[0].value == 0 && keys[1].value == 0 {
                keys.removeFirst()
            }
            let end = keys.last!.time
            return .keyframes(keys.indices.reversed().map { index in
                let ease: MotionEase
                if index == keys.count - 1 {
                    ease = .smooth // The first key has no incoming segment.
                } else {
                    switch keys[index + 1].ease {
                    case .linear: ease = .linear
                    case .smooth: ease = .smooth
                    case .curve(let curve):
                        ease = .curve(TimingCurve(1 - curve.x2, 1 - curve.y2, 1 - curve.x1, 1 - curve.y1))
                    }
                }
                return MotionKeyframe(time: end - keys[index].time, value: 1 - keys[index].value, ease: ease)
            })
        }
        let end = max(duration, 0.05)
        let hold: TimeInterval
        if case .spring(_, let delay) = self { hold = max(0, delay) } else { hold = 0 }
        let reversedDuration = max(0.001, end - hold)
        var samples: [(time: Double, value: Double)] = []
        for step in 0...160 {
            let time = reversedDuration * Double(step) / 160
            let value = 1 - value(at: end - time)
            samples.append((time, value))
        }
        return .keyframes(CurveSketch.keyframes(from: samples, tolerance: 0.008))
    }

    /// Keyframes that trace this curve closely, for editing a spring by hand.
    public func asKeyframes() -> [MotionKeyframe] {
        if case .keyframes(let keys) = self { return keys }
        let end = max(duration, 0.05)
        let samples = stride(from: 0.0, through: end, by: end / 120).map { (time: $0, value: value(at: $0)) }
        return CurveSketch.keyframes(from: samples, tolerance: 0.006)
    }
}

/// One point of a keyframed curve.
public struct MotionKeyframe: Equatable, Sendable {
    /// Seconds from the start of the motion.
    public var time: TimeInterval
    /// Progress: 0 is where the motion starts, 1 where it ends.
    public var value: Double
    /// How the curve arrives here from the previous keyframe (ignored on the first).
    public var ease: MotionEase

    public init(time: TimeInterval, value: Double, ease: MotionEase = .smooth) {
        self.time = time
        self.value = value
        self.ease = ease
    }

    /// The value of a keyframed curve at `time`: the first key's value before it, the
    /// last key's after it.
    public static func value(of keys: [MotionKeyframe], at time: TimeInterval) -> Double {
        guard let first = keys.first, let last = keys.last else { return 1 }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        guard let index = keys.firstIndex(where: { $0.time > time }), index > 0 else { return last.value }
        let a = keys[index - 1]
        let b = keys[index]
        let span = b.time - a.time
        guard span > 0 else { return b.value }
        let s = (time - a.time) / span
        switch b.ease {
        case .linear:
            return a.value + (b.value - a.value) * s
        case .curve(let curve):
            return a.value + (b.value - a.value) * curve.value(at: s)
        case .smooth:
            let m0 = slope(of: keys, at: index - 1)
            let m1 = slope(of: keys, at: index)
            let s2 = s * s
            let s3 = s2 * s
            return (2 * s3 - 3 * s2 + 1) * a.value + (s3 - 2 * s2 + s) * span * m0
                + (-2 * s3 + 3 * s2) * b.value + (s3 - s2) * span * m1
        }
    }

    /// The slope a smooth curve has at key `index`: flat at the ends (a motion starts
    /// still and settles) and at every peak or dip, so an overshoot peaks exactly at
    /// the key placed for it; elsewhere the Fritsch–Carlson monotone slope, so the
    /// curve never swings past a key between two keys.
    static func slope(of keys: [MotionKeyframe], at index: Int) -> Double {
        guard index > 0, index < keys.count - 1 else { return 0 }
        let previous = keys[index - 1]
        let key = keys[index]
        let next = keys[index + 1]
        let left = key.time - previous.time
        let right = next.time - key.time
        guard left > 0, right > 0 else { return 0 }
        let incoming = (key.value - previous.value) / left
        let outgoing = (next.value - key.value) / right
        guard incoming * outgoing > 0 else { return 0 }
        // Weighted harmonic mean of the two slopes (Fritsch–Butland, as MATLAB's pchip):
        // monotone and smooth.
        let w1 = 2 * left + right
        let w2 = left + 2 * right
        return (w1 + w2) / (w1 / incoming + w2 / outgoing)
    }
}

/// How a keyframed curve travels from one key to the next.
public enum MotionEase: Equatable, Sendable {
    /// A smooth path through the neighboring keys, with no swing past them.
    case smooth
    /// A straight line: constant speed, sharp corners at the keys.
    case linear
    /// A timing curve between the two keys, as CSS and Core Animation describe one.
    case curve(TimingCurve)

    public static let easeIn = MotionEase.curve(.easeIn)
    public static let easeOut = MotionEase.curve(.easeOut)
    public static let easeInOut = MotionEase.curve(.easeInOut)

    /// The names a file may use; a custom curve is written as four numbers.
    public var name: String? {
        switch self {
        case .smooth: "smooth"
        case .linear: "linear"
        case .curve(let curve): TimingCurve.named.first { $0.curve == curve }?.name
        }
    }

    public init?(name: String) {
        switch name {
        case "smooth": self = .smooth
        case "linear": self = .linear
        default:
            guard let curve = TimingCurve.named.first(where: { $0.name == name })?.curve else { return nil }
            self = .curve(curve)
        }
    }

    public static let names = ["smooth", "linear"] + TimingCurve.named.map(\.name)
}

/// A cubic Bézier timing curve from (0, 0) to (1, 1) with control points (x1, y1) and
/// (x2, y2), as in CSS `cubic-bezier()` and `CAMediaTimingFunction`. The y values may
/// leave 0…1 to overshoot; the x values stay within it so time only moves forward.
public struct TimingCurve: Equatable, Sendable {
    public var x1: Double
    public var y1: Double
    public var x2: Double
    public var y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = min(max(x1, 0), 1)
        self.y1 = y1
        self.x2 = min(max(x2, 0), 1)
        self.y2 = y2
    }

    public var controlPoints: [Double] { [x1, y1, x2, y2] }

    public static let linear = TimingCurve(0, 0, 1, 1)
    public static let easeIn = TimingCurve(0.42, 0, 1, 1)
    public static let easeOut = TimingCurve(0, 0, 0.58, 1)
    public static let easeInOut = TimingCurve(0.42, 0, 0.58, 1)
    /// The system's "emphasized" curve: fast in, long gentle settle. Content arrives on it.
    public static let settle = TimingCurve(0.2, 0, 0, 1)
    /// Its mirror, slow to start and quick to finish. Content leaves on it.
    public static let leave = TimingCurve(0.3, 0, 0.8, 0.15)

    public static let named: [(name: String, curve: TimingCurve)] = [
        ("easeIn", .easeIn), ("easeOut", .easeOut), ("easeInOut", .easeInOut),
        ("settle", .settle), ("leave", .leave),
    ]

    /// Progress at `x` (0…1 of the way through in time).
    public func value(at x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        let t = parameter(for: x)
        return bezier(t, y1, y2)
    }

    private func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    private func derivative(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
    }

    /// The curve parameter whose x is `x`: Newton's method, then bisection if it stalls.
    private func parameter(for x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let error = bezier(t, x1, x2) - x
            if abs(error) < 1e-7 { return t }
            let slope = derivative(t, x1, x2)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        var low = 0.0
        var high = 1.0
        t = x
        for _ in 0..<40 {
            let value = bezier(t, x1, x2)
            if abs(value - x) < 1e-7 { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return t
    }
}

/// Turns a stroke drawn on the timeline into a few keyframes that follow it.
public enum CurveSketch {
    /// The most keyframes a curve may have.
    public static let maximumKeys = 24

    /// Keyframes along `points` (time in seconds, progress), joined smoothly. The stroke
    /// is read left to right (a pen moving back in time is ignored) and starts at 0
    /// where the pen started. Where the pen lifted it ends at 1; lifted away from 1, the
    /// stroke keeps its last point and settles to 1 shortly after, rather than jumping.
    /// It is simplified until it needs at most `maximumKeys` points and stays within
    /// `tolerance` of the stroke.
    public static func keyframes(from points: [(time: Double, value: Double)],
                                 tolerance: Double = 0.025) -> [MotionKeyframe] {
        var forward: [(time: Double, value: Double)] = []
        for point in points where point.time.isFinite && point.value.isFinite {
            let time = max(0, point.time)
            if let last = forward.last, time <= last.time { continue }
            forward.append((time, point.value))
        }
        guard let first = forward.first, var last = forward.last, last.time > first.time else {
            let end = max(points.last?.time ?? 0.3, 0.05)
            return [MotionKeyframe(time: 0, value: 0), MotionKeyframe(time: end, value: 1)]
        }
        forward[0].value = 0
        if abs(forward[forward.count - 1].value - 1) > 0.02 {
            let settle = max(0.06, (last.time - first.time) * 0.2)
            forward.append((last.time + settle, 1))
        } else {
            forward[forward.count - 1].value = 1
        }
        last = forward[forward.count - 1]
        // Both axes normalized, so the tolerance means the same along each.
        let span = last.time - first.time
        var low = 0.0
        var high = 1.0
        for point in forward {
            low = min(low, point.value)
            high = max(high, point.value)
        }
        let height = max(high - low, 1)
        let normalized = forward.map { CGPoint(x: ($0.time - first.time) / span, y: $0.value / height) }
        // A zero or negative tolerance cannot grow toward the key-count limit.
        // Non-finite tolerances also have no useful geometric meaning.
        var epsilon = tolerance.isFinite && tolerance > 0 ? tolerance : 0.025
        var kept = simplify(normalized, epsilon: epsilon)
        while kept.count > maximumKeys {
            epsilon *= 1.5
            kept = simplify(normalized, epsilon: epsilon)
        }
        return kept.map { index in
            MotionKeyframe(time: (forward[index].time * 1000).rounded() / 1000,
                           value: (forward[index].value * 1000).rounded() / 1000, ease: .smooth)
        }
    }

    /// Ramer–Douglas–Peucker: the indices of the points that keep the line within `epsilon`.
    static func simplify(_ points: [CGPoint], epsilon: Double) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        var keep = Set([0, points.count - 1])
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            let a = points[start]
            let b = points[end]
            var farthest = start
            var distance = 0.0
            for index in (start + 1)..<end {
                let d = Self.distance(points[index], fromLineThrough: a, b)
                if d > distance {
                    distance = d
                    farthest = index
                }
            }
            if distance > epsilon {
                keep.insert(farthest)
                stack.append((start, farthest))
                stack.append((farthest, end))
            }
        }
        return keep.sorted()
    }

    private static func distance(_ p: CGPoint, fromLineThrough a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return Double(hypot(p.x - a.x, p.y - a.y)) }
        return Double(abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length)
    }
}
