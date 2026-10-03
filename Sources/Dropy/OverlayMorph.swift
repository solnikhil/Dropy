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
    /// The morph in progress, to tell where the outline is on screen right now.
    private var active: (frames: [NotchShape], duration: TimeInterval, startedAt: CFTimeInterval)?

    /// The outline as drawn at this moment: part way through a morph, or settled.
    var visibleShape: NotchShape? {
        guard let active else { return currentShape }
        let elapsed = (CACurrentMediaTime() - active.startedAt) / OverlayMotion.slowdown
        return NotchMorph.shape(in: active.frames, duration: active.duration, at: elapsed) ?? currentShape
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
        fill.path = shape.fillPath
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
        Task { @MainActor [weak contentLayer] in
            try? await Task.sleep(for: .seconds(OverlayMotion.wall(duration)))
            // A later morph may have put its own clip in place; leave that one.
            if contentLayer?.mask === mask { contentLayer?.mask = nil }
        }
        return frames.duration
    }
}

/// How the overlay's content arrives and leaves, tuned to system motion: it comes
/// into focus while growing from the notch, and on the way out it blurs, shrinks and
/// fades before the outline closes over it.
@MainActor
enum OverlayMotion {
    /// The content starts once the outline has visibly begun to grow.
    static let revealDelay: TimeInterval = 0.07
    static let revealDuration: TimeInterval = 0.34
    static let hideDuration: TimeInterval = 0.16
    /// Out of focus at the start of a reveal and the end of a hide.
    static let blurRadius: CGFloat = 14
    /// Size relative to its final size at the start of a reveal and the end of a hide.
    static let restScale: CGFloat = 0.9
    /// The system's "emphasized" curves: fast in, long gentle settle; and its mirror.
    static let settleCurve = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
    static let leaveCurve = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.8, 0.15)

    /// Content lower in the overlay arrives later, up to this much, so it reads as
    /// falling out of the notch: header first, then the list, then the preview.
    static let staggerSpan: TimeInterval = 0.1
    /// Each piece of content drifts down into place from this far above.
    static let staggerDrift: CGFloat = 10

    /// System setting "Reduce motion": cross-fade instead of morphing.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Development: `DROPY_MOTION_SLOWDOWN=<n>` plays the overlay's motion n times
    /// slower, to judge it frame by frame. The overlay's root layer runs at 1/n speed;
    /// timers that end the motion wait n times longer (`wall`).
    static let slowdown: Double = ProcessInfo.processInfo.environment["DROPY_MOTION_SLOWDOWN"]
        .flatMap(Double.init).map { min(max($0, 1), 20) } ?? 1

    /// A motion duration in wall-clock seconds.
    static func wall(_ duration: TimeInterval) -> TimeInterval { duration * slowdown }

    /// Brings the content in: focus, scale and opacity together, from the top center.
    static func revealContent(_ view: NSView) {
        guard let layer = view.layer else { return }
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil) + (reduced ? 0 : revealDelay)
        let duration = reduced ? 0.2 : revealDuration
        var animations: [CAAnimation] = [
            basic("opacity", from: 0, to: 1, duration: duration * 0.8, curve: CAMediaTimingFunction(name: .easeOut)),
        ]
        if !reduced {
            animations.append(basic("transform", from: scaleFromTopCenter(restScale, in: view.bounds),
                                    to: CATransform3DIdentity, duration: duration, curve: settleCurve))
            if let blur = attachBlur(to: view) {
                animations.append(basic("filters.\(blur).inputRadius", from: blurRadius, to: 0,
                                        duration: duration, curve: settleCurve))
            }
        }
        run(animations, on: layer, begin: begin, duration: duration, key: "reveal")
        if !reduced { stagger(view.subviews, in: view.bounds, begin: begin, duration: duration) }
        // The filter renders offscreen; it goes as soon as the content is in focus.
        let remaining = begin - layer.convertTime(CACurrentMediaTime(), from: nil) + duration + staggerSpan
        Task { @MainActor [weak view] in
            try? await Task.sleep(for: .seconds(wall(remaining)))
            view?.layer?.filters = nil
        }
    }

    /// After a resize: the new layout fades up inside the moving outline, without the
    /// blur and scale of opening, since the overlay is already open.
    static func relayoutContent(_ view: NSView) {
        guard let layer = view.layer else { return }
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.04
        run([basic("opacity", from: 0, to: 1, duration: 0.26, curve: CAMediaTimingFunction(name: .easeOut))],
            on: layer, begin: begin, duration: 0.26, key: "relayout")
    }

    /// Each piece fades in and drifts down into place, later the lower it sits.
    private static func stagger(_ views: [NSView], in bounds: CGRect, begin: CFTimeInterval, duration: TimeInterval) {
        for view in views {
            guard let layer = view.layer, bounds.height > 0 else { continue }
            let depth = Double(max(0, min(1, (bounds.maxY - view.frame.maxY) / bounds.height)))
            let animations = [
                basic("opacity", from: 0, to: 1, duration: duration * 0.7, curve: CAMediaTimingFunction(name: .easeOut)),
                basic("transform", from: CATransform3DMakeTranslation(0, staggerDrift, 0), to: CATransform3DIdentity,
                      duration: duration, curve: settleCurve),
            ]
            run(animations, on: layer, begin: begin + depth * staggerSpan, duration: duration, key: "reveal")
        }
    }

    /// Takes the content away before the outline closes over it.
    static func hideContent(_ view: NSView) {
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "reveal")
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        var animations: [CAAnimation] = [
            basic("opacity", from: 1, to: 0, duration: hideDuration, curve: leaveCurve),
            basic("transform", from: CATransform3DIdentity, to: scaleFromTopCenter(restScale, in: view.bounds),
                  duration: hideDuration, curve: leaveCurve),
        ]
        if let blur = attachBlur(to: view) {
            animations.append(basic("filters.\(blur).inputRadius", from: 0, to: blurRadius,
                                    duration: hideDuration, curve: leaveCurve))
        }
        layer.opacity = 0
        run(animations, on: layer, begin: now, duration: hideDuration, key: "hide")
    }

    /// Fades the window over the last part of a close, so the outline melts into the
    /// notch (or, without one, into the menu bar) instead of vanishing on a frame.
    static func fadeOut(_ window: NSWindow, after delay: TimeInterval, over duration: TimeInterval) {
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .seconds(wall(delay)))
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = wall(duration)
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window?.animator().alphaValue = 0
            }, completionHandler: nil)
        }
    }

    private static func attachBlur(to view: NSView) -> String? {
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        view.layerUsesCoreImageFilters = true
        blur.name = "focus"
        blur.setValue(0, forKey: kCIInputRadiusKey)
        view.layer?.filters = [blur]
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

    /// AppKit anchors a view's layer at its bottom-left corner; scale around the top
    /// center instead, where the notch is.
    private static func scaleFromTopCenter(_ scale: CGFloat, in bounds: CGRect) -> CATransform3D {
        let anchor = CGPoint(x: bounds.midX, y: bounds.maxY)
        var transform = CATransform3DMakeTranslation(anchor.x, anchor.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -anchor.x, -anchor.y, 0)
    }
}
