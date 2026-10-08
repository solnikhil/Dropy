import CoreGraphics
import Foundation

/// Everything about how the overlay moves: the outline's three motions and how the
/// content inside it arrives and leaves. The built-in styles are animations, and so is
/// every animation file a person, the Animation Studio or an AI agent writes
/// (`AnimationFile` reads and writes them).
public struct DropyAnimation: Equatable, Sendable {
    public var name: String
    public var summary: String
    public var author: String
    /// Out of the notch.
    public var open: NotchMorph.Motion
    /// From one open size to another, as when the window list gives way to a window.
    public var resize: NotchMorph.Motion
    /// Back into the notch. Always forward-only, so it can never bounce back out of the
    /// camera housing.
    public var close: NotchMorph.Motion {
        didSet { if !close.isMonotonic { close.isMonotonic = true } }
    }
    public var content: ContentMotion

    public init(name: String, summary: String = "", author: String = "", open: NotchMorph.Motion,
                resize: NotchMorph.Motion, close: NotchMorph.Motion, content: ContentMotion) {
        self.name = name
        self.summary = summary
        self.author = author
        self.open = open
        self.resize = resize
        var close = close
        close.isMonotonic = true
        self.close = close
        self.content = content
    }

    /// The outline's motions as the overlay plays them.
    public var morph: NotchMorph.Motions { NotchMorph.Motions(open: open, close: close, resize: resize) }

    public enum Part: String, CaseIterable, Sendable {
        case open, resize, close
        public var title: String { rawValue.capitalized }
    }

    public subscript(part: Part) -> NotchMorph.Motion {
        get {
            switch part {
            case .open: open
            case .resize: resize
            case .close: close
            }
        }
        set {
            switch part {
            case .open: open = newValue
            case .resize: resize = newValue
            case .close: close = newValue
            }
        }
    }
}

// MARK: Built-in styles

extension MotionStyle {
    /// The style as an animation, the starting point for a custom one.
    public var animation: DropyAnimation {
        DropyAnimation(name: title, summary: summary, author: "Dropy", open: morph.open, resize: morph.resize,
                       close: morph.close, content: content)
    }

    public var summary: String {
        switch self {
        case .rapid: "Snaps open and shut with no bounce. Best when you open Dropy many times an hour."
        case .balanced: "Smooth with a light settle, and still quick enough for everyday use."
        case .smooth: "Grows out of the notch with a soft settle, and the content drifts into focus."
        }
    }
}

// MARK: Gallery

extension DropyAnimation {
    /// Ready-made animations that show what the format can do. They are written to the
    /// animations folder's Examples as files to start from, and can be added from Settings.
    public static let gallery: [(id: String, animation: DropyAnimation)] = [
        ("springy", springy), ("elastic-drop", elasticDrop), ("snap", snap), ("float", float), ("pop", pop),
        ("jelly", jelly), ("curtain", curtain),
    ]

    private static func spring(_ response: Double, _ damping: Double, delay: Double = 0) -> MotionCurve {
        .spring(MorphSpring(response: response, dampingRatio: damping), delay: delay)
    }

    private static func keys(_ points: (Double, Double, MotionEase)...) -> MotionCurve {
        .keyframes(points.map { MotionKeyframe(time: $0.0, value: $0.1, ease: $0.2) })
    }

    /// Easing that runs past its end and comes back ("ease out back").
    private static let overshootEase = TimingCurve(0.34, 1.4, 0.64, 1)
    /// A long, soft deceleration ("ease out expo").
    private static let glideEase = TimingCurve(0.16, 1, 0.3, 1)

    static let springy = DropyAnimation(
        name: "Springy", summary: "A playful bounce on the way out of the notch, and content that pops into place.",
        author: "Dropy",
        open: .init(width: spring(0.36, 0.62), height: spring(0.42, 0.58, delay: 0.02)),
        resize: .init(width: spring(0.36, 0.7), height: spring(0.4, 0.7)),
        close: .init(width: spring(0.28, 1), height: spring(0.2, 1)),
        content: ContentMotion(revealDelay: 0.06, revealDuration: 0.32, hideDuration: 0.12, relayoutDuration: 0.2,
                               staggerSpan: 0.08, staggerDrift: 10, restScale: 0.9, blurRadius: 0,
                               revealCurve: overshootEase, hideCurve: .leave))

    static let elasticDrop = DropyAnimation(
        name: "Elastic Drop", summary: "Widens first, then drops past its size and rebounds like a stretched band.",
        author: "Dropy",
        open: .init(width: keys((0, 0, .smooth), (0.16, 1.03, .easeOut), (0.3, 1, .smooth)),
                    height: keys((0.04, 0, .smooth), (0.2, 1.14, .easeOut), (0.32, 0.95, .smooth),
                                 (0.42, 1.03, .smooth), (0.52, 1, .smooth))),
        resize: .init(width: spring(0.34, 0.8), height: spring(0.36, 0.78)),
        close: .init(width: keys((0.06, 0, .smooth), (0.26, 1, .easeInOut)),
                     height: keys((0, 0, .smooth), (0.16, 1, .easeIn))),
        content: ContentMotion(revealDelay: 0.1, revealDuration: 0.3, hideDuration: 0.1, relayoutDuration: 0.2,
                               staggerSpan: 0.06, staggerDrift: 14, restScale: 0.94, blurRadius: 6))

    static let snap = DropyAnimation(
        name: "Snap", summary: "As fast as it gets: no bounce, no blur, content there at once.",
        author: "Dropy",
        open: .init(width: spring(0.18, 1), height: spring(0.2, 1)),
        resize: .init(width: spring(0.18, 1), height: spring(0.2, 1)),
        close: .init(width: spring(0.16, 1), height: spring(0.12, 1)),
        content: ContentMotion(revealDelay: 0, revealDuration: 0.12, hideDuration: 0.06, relayoutDuration: 0.1,
                               staggerSpan: 0, staggerDrift: 0, restScale: 1, blurRadius: 0,
                               revealCurve: .easeOut, hideCurve: .easeIn))

    static let float = DropyAnimation(
        name: "Float", summary: "Glides out slowly and the content drifts down into focus. Unhurried on purpose.",
        author: "Dropy",
        open: .init(width: keys((0, 0, .smooth), (0.5, 1, .curve(glideEase))),
                    height: keys((0.08, 0, .smooth), (0.62, 1, .curve(glideEase)))),
        resize: .init(width: spring(0.6, 0.95), height: spring(0.62, 0.95)),
        close: .init(width: keys((0.12, 0, .smooth), (0.45, 1, .easeInOut)),
                     height: keys((0, 0, .smooth), (0.32, 1, .easeInOut))),
        content: ContentMotion(revealDelay: 0.16, revealDuration: 0.6, hideDuration: 0.2, relayoutDuration: 0.36,
                               staggerSpan: 0.18, staggerDrift: 18, restScale: 0.9, blurRadius: 18,
                               revealCurve: glideEase, hideCurve: .leave))

    static let jelly = DropyAnimation(
        name: "Jelly", summary: "Wobbles out of the notch: width and height bounce out of step, like a jelly set down.",
        author: "Dropy",
        open: .init(width: spring(0.36, 0.48), height: spring(0.42, 0.5, delay: 0.03)),
        resize: .init(width: spring(0.34, 0.6), height: spring(0.38, 0.6, delay: 0.03)),
        close: .init(width: spring(0.24, 1), height: spring(0.18, 1)),
        content: ContentMotion(revealDelay: 0.08, revealDuration: 0.34, hideDuration: 0.1, relayoutDuration: 0.2,
                               staggerSpan: 0.1, staggerDrift: 12, restScale: 0.86, blurRadius: 0,
                               revealCurve: overshootEase, hideCurve: .leave))

    static let curtain = DropyAnimation(
        name: "Curtain", summary: "Spans its full width at once, then falls slowly like a curtain, its content following it down.",
        author: "Dropy",
        open: .init(width: spring(0.2, 1),
                    height: keys((0.08, 0, .smooth), (0.5, 1, .easeInOut))),
        resize: .init(width: spring(0.24, 1), height: spring(0.4, 0.95, delay: 0.05)),
        close: .init(width: keys((0.14, 0, .smooth), (0.34, 1, .easeIn)),
                     height: keys((0, 0, .smooth), (0.24, 1, .easeInOut))),
        content: ContentMotion(revealDelay: 0.18, revealDuration: 0.36, hideDuration: 0.12, relayoutDuration: 0.24,
                               staggerSpan: 0.2, staggerDrift: 24, restScale: 1, blurRadius: 0,
                               revealCurve: .settle, hideCurve: .leave))

    static let pop = DropyAnimation(
        name: "Pop", summary: "Bursts sideways past its width, then drops; the content pops in with a little overshoot.",
        author: "Dropy",
        open: .init(width: keys((0, 0, .smooth), (0.12, 1.08, .easeOut), (0.24, 0.98, .smooth), (0.32, 1, .smooth)),
                    height: keys((0.06, 0, .smooth), (0.2, 1.06, .easeOut), (0.3, 1, .smooth))),
        resize: .init(width: spring(0.3, 0.7), height: spring(0.32, 0.72)),
        close: .init(width: spring(0.22, 1), height: spring(0.16, 1)),
        content: ContentMotion(revealDelay: 0.08, revealDuration: 0.28, hideDuration: 0.1, relayoutDuration: 0.18,
                               staggerSpan: 0.05, staggerDrift: 0, restScale: 0.8, blurRadius: 0,
                               revealCurve: TimingCurve(0.34, 1.56, 0.64, 1), hideCurve: .leave))
}

// MARK: Limits

/// What an animation may ask for. Values outside are brought inside with a warning
/// (`AnimationFile`), so no file can make the overlay leave the screen edge, bounce out
/// of the notch, or take so long that opening feels broken.
public enum AnimationLimits {
    /// Seconds for one oscillation of a spring.
    public static let response: ClosedRange<Double> = 0.05...1.5
    /// 1 settles without overshoot; 0.36 overshoots by about 30 %, the most allowed.
    public static let damping: ClosedRange<Double> = 0.36...1
    public static let delay: ClosedRange<Double> = 0...0.5
    public static let keyTime: ClosedRange<Double> = 0...2
    /// Below 0 pulls back past the start; above 1 overshoots the end.
    public static let keyValue: ClosedRange<Double> = -0.5...1.3
    public static let keyCount: ClosedRange<Int> = 2...CurveSketch.maximumKeys
    /// The longest each motion may play, in seconds; longer ones are sped up to fit.
    public static func longest(_ part: DropyAnimation.Part) -> TimeInterval {
        switch part {
        case .open: 1.6
        case .resize: 1.2
        case .close: 1
        }
    }

    public static let revealDelay: ClosedRange<Double> = 0...0.6
    public static let revealDuration: ClosedRange<Double> = 0.05...1
    public static let hideDuration: ClosedRange<Double> = 0.03...0.6
    public static let relayoutDuration: ClosedRange<Double> = 0.05...0.8
    public static let cascade: ClosedRange<Double> = 0...0.4
    public static let drift: ClosedRange<Double> = -40...40
    public static let startScale: ClosedRange<Double> = 0.5...1.2
    public static let blur: ClosedRange<Double> = 0...30
    /// The y values of a timing curve's control points (x stays within 0…1).
    public static let curveY: ClosedRange<Double> = -1...2
}

// MARK: Cost

public enum AnimationCost: String, Sendable, Comparable {
    case light, moderate, heavy

    public var title: String { rawValue.capitalized }

    public static func < (a: AnimationCost, b: AnimationCost) -> Bool {
        let order: [AnimationCost] = [.light, .moderate, .heavy]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

extension DropyAnimation {
    /// A rough idea of the work an opening asks of the Mac. The outline is a filled
    /// shape and costs almost nothing at any speed; the content's blur is the expensive
    /// part, since it renders the content offscreen for as long as it is out of focus.
    public var cost: (level: AnimationCost, reason: String) {
        let blur = Double(content.blurRadius)
        let focusTime = Int(((content.revealDuration + content.staggerSpan) * 1000).rounded())
        if blur <= 0 {
            return (.light, "No blur: the content only fades, scales and moves, which costs almost nothing.")
        }
        if blur <= 12, content.revealDuration <= 0.45 {
            return (.moderate, "The blur renders the content offscreen for about \(focusTime) ms of each opening.")
        }
        return (.heavy, "A strong or long blur renders the content offscreen for about \(focusTime) ms of each opening; on battery or a busy Mac it may drop frames.")
    }
}

// MARK: Surprise

extension DropyAnimation {
    /// A new animation made at random from tasteful ranges: always within the limits,
    /// never slow, and with the width leading the height as the built-in styles do.
    public static func surprise<G: RandomNumberGenerator>(using generator: inout G) -> DropyAnimation {
        func pick(_ range: ClosedRange<Double>, step: Double = 0.01) -> Double {
            (Double.random(in: range, using: &generator) / step).rounded() * step
        }
        func spring(_ response: ClosedRange<Double>, _ damping: ClosedRange<Double>, delay: ClosedRange<Double> = 0...0) -> MotionCurve {
            .spring(MorphSpring(response: pick(response), dampingRatio: pick(damping)), delay: pick(delay))
        }
        // Opening: a spring, or keyframes with one overshoot and a settle.
        let openWidth: MotionCurve
        let openHeight: MotionCurve
        if Bool.random(using: &generator) {
            openWidth = spring(0.24...0.4, 0.6...1)
            openHeight = spring(0.28...0.42, 0.6...1, delay: 0...0.04)
        } else {
            let peak = pick(1.03...1.14)
            let arrive = pick(0.14...0.24)
            let settle = pick(0.1...0.2)
            let wait = pick(0...0.05)
            openWidth = .keyframes([MotionKeyframe(time: 0, value: 0),
                                    MotionKeyframe(time: arrive, value: pick(1...1.04), ease: .easeOut),
                                    MotionKeyframe(time: arrive + settle, value: 1, ease: .smooth)])
            openHeight = .keyframes([MotionKeyframe(time: wait, value: 0),
                                     MotionKeyframe(time: wait + arrive + 0.02, value: peak, ease: .easeOut),
                                     MotionKeyframe(time: wait + arrive + 0.02 + settle, value: pick(0.96...0.99), ease: .smooth),
                                     MotionKeyframe(time: wait + arrive + 0.02 + settle * 1.8, value: 1, ease: .smooth)])
        }
        let blur = Bool.random(using: &generator) ? 0 : pick(4...12, step: 1)
        let curves: [TimingCurve] = [.settle, .easeOut, TimingCurve(0.34, 1.3, 0.64, 1), TimingCurve(0.16, 1, 0.3, 1)]
        let names = ["Breeze", "Comet", "Ripple", "Bloom", "Drift", "Flicker", "Swoop", "Pulse", "Glint", "Echo"]
        return DropyAnimation(
            name: names[Int.random(in: 0..<names.count, using: &generator)], summary: "Made by Surprise Me.", author: "",
            open: .init(width: openWidth, height: openHeight),
            resize: .init(width: spring(0.26...0.4, 0.7...1), height: spring(0.28...0.44, 0.7...1)),
            close: .init(width: spring(0.18...0.3, 1...1), height: spring(0.14...0.24, 1...1)),
            content: ContentMotion(revealDelay: pick(0...0.12), revealDuration: pick(0.16...0.4), hideDuration: pick(0.06...0.16),
                                   relayoutDuration: pick(0.12...0.28), staggerSpan: pick(0...0.14), staggerDrift: CGFloat(pick(0...16, step: 1)),
                                   restScale: CGFloat(pick(0.86...1)), blurRadius: CGFloat(blur),
                                   revealCurve: curves[Int.random(in: 0..<curves.count, using: &generator)], hideCurve: .leave))
    }
}
