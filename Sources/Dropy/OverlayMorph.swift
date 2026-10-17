import AppKit
import DropyCore
import QuartzCore

/// Draws the overlay's black outline and morphs it between the notch and the open
/// overlay. The outline is a filled shape layer, not a mask: masking the layer tree
/// forced an offscreen pass on every composite, and a fill costs nothing extra once
/// it stops moving.
final class MorphBackdropView: NSView {
    private let fill = CAShapeLayer()
    private let hairline = CAShapeLayer()
    /// The outline as last set; a morph sets its end shape here at once.
    private(set) var currentShape: NotchShape?
    /// A see-through cut-out for a docked window, with that window's corner radius.
    /// The outline is drawn around it, so the real window beneath shows through.
    var hole: (rect: CGRect, radius: CGFloat)? {
        didSet { if let currentShape { set(currentShape) } }
    }
    /// The morph in progress, to tell where the outline is on screen right now.
    private var active: (frames: [NotchShape], duration: TimeInterval, startedAt: CFTimeInterval)?
    /// How long the latest morph takes to cover its end shape's place (`NotchMorph.coverTime`).
    private(set) var coverDuration: TimeInterval = 0
    /// How many times slower than real time its layers run (a slowed-down preview).
    var slowdown = OverlayMotion.slowdown

    /// The outline as drawn at this moment: part way through a morph, or settled.
    var visibleShape: NotchShape? {
        guard let active else { return currentShape }
        let elapsed = (CACurrentMediaTime() - active.startedAt) / slowdown
        return NotchMorph.shape(in: active.frames, duration: active.duration, at: elapsed) ?? currentShape
    }

    /// Wall-clock seconds until the morph in progress ends; 0 at rest.
    var morphRemaining: TimeInterval {
        guard let active else { return 0 }
        return max(0, active.duration * slowdown - (CACurrentMediaTime() - active.startedAt))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Pure black continues the camera housing, so the overlay reads as the notch
        // growing rather than a window appearing beneath it.
        fill.fillColor = NSColor.black.cgColor
        hairline.fillColor = nil
        hairline.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        hairline.lineWidth = 1
        layer?.addSublayer(fill)
        layer?.addSublayer(hairline)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        hairline.frame = bounds
        CATransaction.commit()
    }

    /// Sets the outline at once.
    func set(_ shape: NotchShape) {
        currentShape = shape
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let hole {
            let path = CGMutablePath()
            path.addPath(shape.fillPath)
            path.addRoundedRect(in: hole.rect, cornerWidth: hole.radius, cornerHeight: hole.radius)
            fill.fillRule = .evenOdd
            fill.path = path
        } else {
            fill.fillRule = .nonZero
            fill.path = shape.fillPath
        }
        hairline.path = shape.strokePath
        CATransaction.commit()
    }

    func settle(_ shape: NotchShape) {
        active = nil
        fill.removeAllAnimations()
        hairline.removeAllAnimations()
        set(shape)
    }

    /// Moves the outline from `start` to `end` along precomputed spring frames and
    /// returns how long that takes. The model value is the end shape, so the outline
    /// stays there afterwards.
    ///
    /// `content` is clipped to the moving outline while it moves, so nothing shows
    /// outside the shape. The clip is a mask, which costs an offscreen pass per
    /// composite, so it is removed once the outline settles.
    @discardableResult
    func morph(from start: NotchShape, to end: NotchShape, motion: NotchMorph.Motion,
               clipping content: NSView? = nil) -> TimeInterval {
        let frames = NotchMorph.frames(from: start, to: end, motion: motion)
        set(end)
        active = (frames.shapes, frames.duration, CACurrentMediaTime())
        coverDuration = NotchMorph.coverTime(shapes: frames.shapes, keyTimes: frames.keyTimes, duration: frames.duration)
        func keyframes(_ path: (NotchShape) -> CGPath?) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: "path")
            animation.values = frames.shapes.compactMap(path)
            animation.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
            animation.duration = frames.duration
            animation.calculationMode = .linear
            return animation
        }
        fill.add(keyframes { $0.fillPath }, forKey: "morph")
        hairline.add(keyframes { $0.strokePath }, forKey: "morph")

        guard let content, let contentLayer = content.layer else { return frames.duration }
        // The outline in the content's own coordinates.
        let offset = CGAffineTransform(translationX: -content.frame.minX, y: -content.frame.minY)
        func shifted(_ shape: NotchShape) -> CGPath? {
            var transform = offset
            return shape.fillPath.copy(using: &transform)
        }
        let mask = CAShapeLayer()
        mask.frame = content.bounds
        mask.fillColor = NSColor.black.cgColor
        mask.path = shifted(end)
        mask.add(keyframes(shifted), forKey: "morph")
        contentLayer.mask = mask
        let duration = frames.duration
        let wall = duration * slowdown
        Task { @MainActor [weak contentLayer] in
            try? await Task.sleep(for: .seconds(wall))
            // A later morph may have put its own clip in place; leave that one.
            if contentLayer?.mask === mask { contentLayer?.mask = nil }
        }
        return frames.duration
    }
}

/// How the overlay moves: the outline's motions and how its content arrives and
/// leaves. It comes into focus while growing from the notch, and on the way out it
/// blurs, shrinks and fades before the outline closes over it. Everything comes from
/// the animation in use, a built-in style or the person's own.
@MainActor
enum OverlayMotion {
    /// Read at the start of each motion; one already playing finishes as it began.
    static var animation: DropyAnimation = MotionStyle.balanced.animation
    /// The outline's motions.
    static var morph: NotchMorph.Motions { animation.morph }
    /// How far past its target the outline goes, for the overlay window's margin.
    static var reach: Double { morph.reach }
    private static var content: ContentMotion { animation.content }

    /// System setting "Reduce motion": cross-fade instead of morphing.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Development: `DROPY_MOTION_SLOWDOWN=<n>` plays the overlay's motion n times
    /// slower, to judge it frame by frame. The overlay's root layer runs at 1/n speed;
    /// timers that end the motion wait n times longer (`wall`).
    static let slowdown: Double = ProcessInfo.processInfo.environment["DROPY_MOTION_SLOWDOWN"]
        .flatMap(Double.init).map { min(max($0, 1), 20) } ?? 1

    /// A motion duration in wall-clock seconds.
    static func wall(_ duration: TimeInterval) -> TimeInterval { duration * slowdown }

    // MARK: Content, on views (the overlay)

    /// Brings the content in: focus, scale and opacity together, from the point the
    /// overlay grows out of (the top center at the notch).
    static func revealContent(_ view: NSView, motion: ContentMotion? = nil, slowdown: Double = slowdown,
                              position: OverlayPosition = .notch) {
        guard let layer = view.layer else { return }
        let parts = view.subviews.compactMap { subview in subview.layer.map { ($0, subview.frame) } }
        reveal(layer, parts: parts, bounds: view.bounds, motion: motion ?? content, slowdown: slowdown,
               position: position) {
            view.layerUsesCoreImageFilters = true
        }
    }

    /// After a resize: the new layout fades up inside the moving outline, without the
    /// blur and scale of opening, since the overlay is already open.
    static func relayoutContent(_ view: NSView, motion: ContentMotion? = nil) {
        guard let layer = view.layer else { return }
        relayout(layer, motion: motion ?? content)
    }

    /// Takes the content away before the outline closes over it.
    static func hideContent(_ view: NSView, motion: ContentMotion? = nil, position: OverlayPosition = .notch) {
        guard let layer = view.layer else { return }
        hide(layer, bounds: view.bounds, motion: motion ?? content, position: position) {
            view.layerUsesCoreImageFilters = true
        }
    }

    // MARK: Content, on layers (shared with the Animation Studio's preview)

    /// Reveals `layer` and, cascading from the top, each of `parts` (sublayers with their
    /// frames in `bounds`). `enableFilters` is called before a blur is attached.
    static func reveal(_ layer: CALayer, parts: [(CALayer, CGRect)], bounds: CGRect, motion: ContentMotion,
                       slowdown: Double, position: OverlayPosition = .notch, enableFilters: () -> Void) {
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil) + (reduced ? 0 : motion.revealDelay)
        let duration = reduced ? 0.2 : motion.revealDuration
        let curve = motion.revealCurve.mediaTimingFunction
        var animations: [CAAnimation] = [
            basic("opacity", from: 0, to: 1, duration: duration * 0.8, curve: CAMediaTimingFunction(name: .easeOut)),
        ]
        if !reduced {
            animations.append(basic("transform", from: scale(motion.restScale, from: position, in: bounds),
                                    to: CATransform3DIdentity, duration: duration, curve: curve))
            if motion.blurRadius > 0, let blur = attachBlur(to: layer, enableFilters: enableFilters) {
                animations.append(basic("filters.\(blur).inputRadius", from: motion.blurRadius, to: 0,
                                        duration: duration, curve: curve))
            }
        }
        run(animations, on: layer, begin: begin, duration: duration, key: "reveal")
        if !reduced { stagger(parts, in: bounds, begin: begin, duration: duration, motion: motion, position: position) }
        // The filter renders offscreen; it goes as soon as the content is in focus.
        let remaining = begin - layer.convertTime(CACurrentMediaTime(), from: nil) + duration + motion.staggerSpan
        Task { @MainActor [weak layer] in
            try? await Task.sleep(for: .seconds(remaining * slowdown))
            layer?.filters = nil
        }
    }

    static func relayout(_ layer: CALayer, motion: ContentMotion) {
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.04
        let duration = motion.relayoutDuration
        run([basic("opacity", from: 0, to: 1, duration: duration, curve: CAMediaTimingFunction(name: .easeOut))],
            on: layer, begin: begin, duration: duration, key: "relayout")
    }

    static func hide(_ layer: CALayer, bounds: CGRect, motion: ContentMotion, position: OverlayPosition = .notch,
                     enableFilters: () -> Void) {
        layer.removeAnimation(forKey: "reveal")
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let curve = motion.hideCurve.mediaTimingFunction
        var animations: [CAAnimation] = [
            basic("opacity", from: 1, to: 0, duration: motion.hideDuration, curve: curve),
            basic("transform", from: CATransform3DIdentity, to: scale(motion.restScale, from: position, in: bounds),
                  duration: motion.hideDuration, curve: curve),
        ]
        if motion.blurRadius > 0, let blur = attachBlur(to: layer, enableFilters: enableFilters) {
            animations.append(basic("filters.\(blur).inputRadius", from: 0, to: motion.blurRadius,
                                    duration: motion.hideDuration, curve: curve))
        }
        layer.opacity = 0
        run(animations, on: layer, begin: now, duration: motion.hideDuration, key: "hide")
    }

    /// Each piece fades in and drifts into place from the edge the overlay grows out
    /// of (down from the notch), later the farther it sits from where the cascade starts.
    private static func stagger(_ parts: [(CALayer, CGRect)], in bounds: CGRect, begin: CFTimeInterval,
                                duration: TimeInterval, motion: ContentMotion, position: OverlayPosition) {
        let curve = motion.revealCurve.mediaTimingFunction
        let drift = position.driftDirection
        for (layer, frame) in parts {
            guard bounds.height > 0 else { continue }
            let distance = position.cascadesFromBottom ? frame.minY - bounds.minY : bounds.maxY - frame.maxY
            let depth = Double(max(0, min(1, distance / bounds.height)))
            let start = CATransform3DMakeTranslation(drift.dx * motion.staggerDrift, drift.dy * motion.staggerDrift, 0)
            let animations = [
                basic("opacity", from: 0, to: 1, duration: duration * 0.7, curve: CAMediaTimingFunction(name: .easeOut)),
                basic("transform", from: start, to: CATransform3DIdentity, duration: duration, curve: curve),
            ]
            run(animations, on: layer, begin: begin + depth * motion.staggerSpan, duration: duration, key: "reveal")
        }
    }

    /// Fades the window over the last part of a close, so the outline melts into the
    /// notch (or, without one, into the menu bar) instead of vanishing on a frame.
    static func fadeOut(_ window: NSWindow, after delay: TimeInterval, over duration: TimeInterval,
                        slowdown: Double = slowdown) {
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .seconds(delay * slowdown))
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration * slowdown
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window?.animator().alphaValue = 0
            }, completionHandler: nil)
        }
    }

    private static func attachBlur(to layer: CALayer, enableFilters: () -> Void) -> String? {
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        enableFilters()
        blur.name = "focus"
        blur.setValue(0, forKey: kCIInputRadiusKey)
        layer.filters = [blur]
        return blur.name
    }

    private static func basic(_ keyPath: String, from: Any, to: Any, duration: TimeInterval,
                              curve: CAMediaTimingFunction) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = (from as? CATransform3D).map { NSValue(caTransform3D: $0) } ?? from
        animation.toValue = (to as? CATransform3D).map { NSValue(caTransform3D: $0) } ?? to
        animation.duration = duration
        animation.timingFunction = curve
        return animation
    }

    /// Runs the animations as one group; held at both ends so nothing jumps while
    /// waiting to begin or after it ends.
    private static func run(_ animations: [CAAnimation], on layer: CALayer, begin: CFTimeInterval,
                            duration: TimeInterval, key: String) {
        let group = CAAnimationGroup()
        group.animations = animations
        group.beginTime = begin
        group.duration = duration
        group.fillMode = .both
        group.isRemovedOnCompletion = key != "hide"
        layer.add(group, forKey: key)
    }

    /// AppKit anchors a view's layer at its bottom-left corner; scale around the point
    /// the overlay grows from instead (the top center, where the notch is).
    private static func scale(_ scale: CGFloat, from position: OverlayPosition, in bounds: CGRect) -> CATransform3D {
        let unit = position.growthAnchor
        let anchor = CGPoint(x: bounds.minX + bounds.width * unit.x, y: bounds.minY + bounds.height * unit.y)
        var transform = CATransform3DMakeTranslation(anchor.x, anchor.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -anchor.x, -anchor.y, 0)
    }
}

extension TimingCurve {
    var mediaTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
    }
}
