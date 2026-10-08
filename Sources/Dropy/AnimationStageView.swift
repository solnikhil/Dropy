import AppKit
import SwiftUI
import DropyCore

/// A miniature top of a screen, with a notch and a menu bar, where an animation plays:
/// the outline from the same frames the overlay uses, and the stand-in content through
/// the overlay's own reveal, relayout and hide. Drawn with layers only, so it can be
/// scaled to any size.
final class AnimationStageView: NSView {
    /// The scene in points before scaling: wide enough to fill any frame sideways; it
    /// is scaled so the larger overlay fits the frame's height.
    static let viewport = CGSize(width: 2400, height: 560)
    static let notch = CGSize(width: 200, height: 32)
    static let firstSize = CGSize(width: 600, height: 360)
    static let secondSize = CGSize(width: 720, height: 430)
    /// The part of the scene that must always show.
    static let focus = CGSize(width: 900, height: secondSize.height + 50)

    /// Called when a motion starts (with the media time it started at and the
    /// slowdown) and with nil when playback ends.
    var onPart: ((DropyAnimation.Part?, CFTimeInterval, Double) -> Void)?
    /// The animation last played or shown, so a SwiftUI update can tell a change.
    private(set) var animation: DropyAnimation?

    private let world = CALayer()
    private let wallpaper = CAGradientLayer()
    private let menuBar = CALayer()
    private let notchLayer = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let hairline = CAShapeLayer()
    private let content = CALayer()
    private let contentMask = CAShapeLayer()
    private var pieces: [CALayer] = []
    private var generation = UUID()
    /// The outline as it rests now.
    private var resting: NotchShape?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    private func build() {
        guard let root = layer else { return }
        root.backgroundColor = NSColor.black.cgColor
        world.bounds = CGRect(origin: .zero, size: Self.viewport)
        world.anchorPoint = CGPoint(x: 0.5, y: 1)
        root.addSublayer(world)

        wallpaper.frame = world.bounds
        wallpaper.colors = [NSColor(srgbRed: 0.16, green: 0.27, blue: 0.45, alpha: 1).cgColor,
                            NSColor(srgbRed: 0.42, green: 0.32, blue: 0.52, alpha: 1).cgColor,
                            NSColor(srgbRed: 0.85, green: 0.55, blue: 0.45, alpha: 1).cgColor]
        wallpaper.startPoint = CGPoint(x: 0, y: 0)
        wallpaper.endPoint = CGPoint(x: 1, y: 1)
        world.addSublayer(wallpaper)

        menuBar.frame = CGRect(x: 0, y: Self.viewport.height - Self.notch.height, width: Self.viewport.width, height: Self.notch.height)
        menuBar.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
        world.addSublayer(menuBar)
        let center = Self.viewport.width / 2
        let items: [(CGFloat, CGFloat)] = [(-640, 18), (-602, 46), (-542, 40), (-488, 52), (-420, 44),
                                           (330, 22), (370, 22), (410, 46), (470, 30), (518, 60)]
        for (offset, width) in items {
            let x = center + offset
            let item = CALayer()
            item.frame = CGRect(x: x, y: (Self.notch.height - 11) / 2, width: width, height: 11)
            item.backgroundColor = NSColor(white: 1, alpha: 0.7).cgColor
            item.cornerRadius = 3
            menuBar.addSublayer(item)
        }

        fill.fillColor = NSColor.black.cgColor
        hairline.fillColor = nil
        hairline.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        hairline.lineWidth = 1.5
        world.addSublayer(fill)
        content.mask = contentMask
        contentMask.fillColor = NSColor.black.cgColor
        for kind in PreviewContentLayout.kinds {
            let piece = CALayer()
            piece.backgroundColor = kind.color
            piece.cornerRadius = kind.radius
            piece.cornerCurve = .continuous
            content.addSublayer(piece)
            pieces.append(piece)
        }
        world.addSublayer(content)
        world.addSublayer(hairline)
        // The camera housing sits over everything, so the outline comes out from under it.
        notchLayer.fillColor = NSColor.black.cgColor
        notchLayer.path = NotchShape.notch(size: Self.notch, in: Self.viewport).fillPath
        world.addSublayer(notchLayer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setClosed()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = min(bounds.width / Self.focus.width, bounds.height / Self.focus.height)
        world.position = CGPoint(x: bounds.midX, y: bounds.maxY)
        world.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    // MARK: Playing

    /// Plays `parts` in order (all three by default), `slowdown` times slower than real
    /// time, starting over after a pause when `loop` is set.
    func play(_ animation: DropyAnimation, parts: [DropyAnimation.Part] = DropyAnimation.Part.allCases,
              slowdown: Double = 1, loop: Bool = false) {
        let token = UUID()
        generation = token
        self.animation = animation
        let slowdown = min(max(slowdown, 1), 20)
        Task { @MainActor [weak self] in
            repeat {
                guard let self, self.generation == token else { return }
                await self.run(animation, parts: parts, slowdown: slowdown, token: token)
                guard self.generation == token else { return }
                self.onPart?(nil, CACurrentMediaTime(), slowdown)
                if loop { try? await Task.sleep(for: .seconds(0.8)) }
            } while loop
        }
    }

    /// Shows the animation's resting state for `part` without moving: closed before an
    /// opening, open otherwise.
    func show(_ animation: DropyAnimation, open: Bool) {
        generation = UUID()
        self.animation = animation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if open { setOpen(size: Self.firstSize) } else { setClosed() }
        CATransaction.commit()
    }

    func stop() {
        generation = UUID()
        onPart?(nil, CACurrentMediaTime(), 1)
    }

    private func run(_ animation: DropyAnimation, parts: [DropyAnimation.Part], slowdown: Double, token: UUID) async {
        world.speed = Float(1 / slowdown)
        func wait(_ seconds: TimeInterval) async -> Bool {
            try? await Task.sleep(for: .seconds(seconds * slowdown))
            return generation == token
        }
        for (index, part) in parts.enumerated() {
            switch part {
            case .open:
                instantly { setClosed() }
                guard await wait(0.25) else { return }
                onPart?(.open, CACurrentMediaTime(), slowdown)
                let end = NotchShape.open(body: body(Self.firstSize))
                layoutContent(size: Self.firstSize)
                morph(to: end, motion: animation.morph.open)
                OverlayMotion.reveal(content, parts: pieces.map { ($0, $0.frame) }, bounds: content.bounds,
                                     motion: animation.content, slowdown: slowdown) {}
                guard await wait(animation.morph.open.duration + (index < parts.count - 1 ? AnimationDemo.holdOpen : 0.2)) else { return }
            case .resize:
                if index == 0 || resting == nil || resting?.body.size != Self.firstSize {
                    instantly { setOpen(size: Self.firstSize) }
                    guard await wait(0.35) else { return }
                }
                onPart?(.resize, CACurrentMediaTime(), slowdown)
                layoutContent(size: Self.secondSize)
                morph(to: .open(body: body(Self.secondSize)), motion: animation.morph.resize)
                OverlayMotion.relayout(content, motion: animation.content)
                guard await wait(animation.morph.resize.duration + (index < parts.count - 1 ? AnimationDemo.holdResized : 0.2)) else { return }
            case .close:
                if index == 0 || resting == nil || resting?.body.height ?? 0 <= Self.notch.height {
                    instantly { setOpen(size: Self.firstSize) }
                    guard await wait(0.35) else { return }
                }
                onPart?(.close, CACurrentMediaTime(), slowdown)
                OverlayMotion.hide(content, bounds: content.bounds, motion: animation.content) {}
                morph(to: NotchShape.notch(size: Self.notch, in: Self.viewport), motion: animation.morph.close)
                guard await wait(animation.morph.close.duration + 0.3) else { return }
            }
        }
    }

    // MARK: Pieces

    private func body(_ size: CGSize) -> CGRect {
        CGRect(x: (Self.viewport.width - size.width) / 2, y: Self.viewport.height - size.height,
               width: size.width, height: size.height)
    }

    private func instantly(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    private func setClosed() {
        let shape = NotchShape.notch(size: Self.notch, in: Self.viewport)
        for layer in [fill, hairline, contentMask, content] { layer.removeAllAnimations() }
        pieces.forEach { $0.removeAllAnimations() }
        fill.path = shape.fillPath
        hairline.path = shape.strokePath
        layoutContent(size: Self.firstSize)
        contentMask.path = shape.fillPath.copy(using: [CGAffineTransform(translationX: -content.frame.minX, y: -content.frame.minY)])
        // Fully opaque at rest, as the overlay's content is: a reveal animates from 0 and
        // is then removed, and the closed outline keeps the content under the notch.
        content.opacity = 1
        content.transform = CATransform3DIdentity
        content.filters = nil
        resting = shape
    }

    private func setOpen(size: CGSize) {
        let shape = NotchShape.open(body: body(size))
        for layer in [fill, hairline, contentMask, content] { layer.removeAllAnimations() }
        pieces.forEach { $0.removeAllAnimations() }
        fill.path = shape.fillPath
        hairline.path = shape.strokePath
        layoutContent(size: size)
        contentMask.path = shape.fillPath.copy(using: [CGAffineTransform(translationX: -content.frame.minX, y: -content.frame.minY)])
        content.opacity = 1
        content.transform = CATransform3DIdentity
        content.filters = nil
        resting = shape
    }

    private func layoutContent(size: CGSize) {
        instantly {
            content.frame = body(size)
            contentMask.frame = content.bounds
            for (piece, rect) in zip(pieces, PreviewContentLayout.frames(in: content.bounds, notchHeight: Self.notch.height)) {
                piece.frame = rect
            }
        }
    }

    /// Moves the outline (and the content's clip) from where it rests to `end`.
    private func morph(to end: NotchShape, motion: NotchMorph.Motion) {
        let start = resting ?? end
        let frames = NotchMorph.frames(from: start, to: end, motion: motion)
        func keyframes(_ path: (NotchShape) -> CGPath?) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: "path")
            animation.values = frames.shapes.compactMap(path)
            animation.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
            animation.duration = frames.duration
            animation.calculationMode = .linear
            return animation
        }
        let offset = CGAffineTransform(translationX: -content.frame.minX, y: -content.frame.minY)
        instantly {
            fill.path = end.fillPath
            hairline.path = end.strokePath
            contentMask.path = end.fillPath.copy(using: [offset])
        }
        fill.add(keyframes { $0.fillPath }, forKey: "morph")
        hairline.add(keyframes { $0.strokePath }, forKey: "morph")
        contentMask.add(keyframes { shape in
            var transform = offset
            return shape.fillPath.copy(using: &transform)
        }, forKey: "morph")
        resting = end
    }
}

private extension CGPath {
    func copy(using transforms: [CGAffineTransform]) -> CGPath? {
        var transform = transforms.reduce(CGAffineTransform.identity) { $0.concatenating($1) }
        return copy(using: &transform)
    }
}

/// The stage in SwiftUI. It plays whenever `animation` or `request` changes.
struct AnimationStage: NSViewRepresentable {
    let animation: DropyAnimation
    /// Changing this replays (e.g. a Replay button), with these parts and settings.
    var request: Int = 0
    var parts: [DropyAnimation.Part] = DropyAnimation.Part.allCases
    var slowdown: Double = 1
    var loop = false
    /// Plays on its own when the animation changes.
    var autoplay = true
    var onPart: ((DropyAnimation.Part?, CFTimeInterval, Double) -> Void)?

    final class Coordinator {
        var request = 0
        var loop = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnimationStageView {
        let view = AnimationStageView(frame: .zero)
        view.onPart = onPart
        context.coordinator.request = request
        context.coordinator.loop = loop
        if autoplay { view.play(animation, parts: parts, slowdown: slowdown, loop: loop) } else { view.show(animation, open: false) }
        return view
    }

    func updateNSView(_ view: AnimationStageView, context: Context) {
        view.onPart = onPart
        let replay = context.coordinator.request != request || context.coordinator.loop != loop
            || (autoplay && view.animation != animation)
        context.coordinator.request = request
        context.coordinator.loop = loop
        if replay { view.play(animation, parts: parts, slowdown: slowdown, loop: loop) }
    }

    static func dismantleNSView(_ view: AnimationStageView, coordinator: Coordinator) { view.stop() }
}
