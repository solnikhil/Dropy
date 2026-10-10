import AppKit
import DropyCore

/// Plays an animation on the notch with stand-in content: opening, a resize, and
/// closing, with the overlay's own outline and content code. The Animation Studio's
/// "Play on Notch" and `Dropy animation play` use it. Nothing is captured or docked.
@MainActor
final class AnimationDemo {
    /// The overlay's two sizes in the demo: the window list, then a chosen window.
    static let firstSize = CGSize(width: 640, height: 400)
    static let secondSize = CGSize(width: 760, height: 470)
    static let holdOpen: TimeInterval = 0.9
    static let holdResized: TimeInterval = 0.8

    private var panel: OverlayPanel?
    private var generation = UUID()
    var isPlaying: Bool { panel != nil }

    /// Plays `animation` `slowdown` times slower than real time. Returns how long it
    /// takes in seconds.
    @discardableResult
    func play(_ animation: DropyAnimation, slowdown: Double = 1) -> TimeInterval {
        guard let slowdown = AnimationPlayback.slowdown(slowdown) else { return 0 }
        stop()
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return 0 }
        let token = UUID()
        generation = token
        let notch = OverlayController.notchSize(on: screen)
        let margin = NotchMorph.overshootMargin(for: Self.secondSize, reach: animation.morph.reach)
        let size = CGSize(width: Self.secondSize.width + 2 * margin, height: Self.secondSize.height + margin)
        let frame = OverlayGeometry.pixelAligned(CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                                                        width: size.width, height: size.height),
                                                 scale: screen.backingScaleFactor)
        let panel = OverlayPanel.make(contentRect: frame)
        panel.ignoresMouseEvents = true
        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.speed = Float(1 / slowdown)
        panel.contentView = root
        let backdrop = MorphBackdropView(frame: root.bounds)
        backdrop.slowdown = slowdown
        root.addSubview(backdrop)
        func body(_ size: CGSize) -> CGRect {
            CGRect(x: (frame.width - size.width) / 2, y: frame.height - size.height, width: size.width, height: size.height)
        }
        let content = PreviewContentView(frame: body(Self.firstSize), notchHeight: notch?.height ?? 32)
        root.addSubview(content)
        let closed = NotchShape.notch(size: notch ?? CGSize(width: 180, height: NSStatusBar.system.thickness), in: frame.size)
        panel.orderFrontRegardless()
        self.panel = panel

        let open = backdrop.morph(from: closed, to: .open(body: body(Self.firstSize)), motion: animation.morph.open,
                                  clipping: content)
        OverlayMotion.revealContent(content, motion: animation.content, slowdown: slowdown)
        if notch == nil {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25 * slowdown; panel.animator().alphaValue = 1 }
        }
        let resize = animation.morph.resize.duration
        let close = animation.morph.close.duration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds((open + Self.holdOpen) * slowdown))
            guard let self, self.generation == token else { return }
            let start = backdrop.visibleShape ?? .open(body: body(Self.firstSize))
            content.frame = body(Self.secondSize)
            backdrop.morph(from: start, to: .open(body: body(Self.secondSize)), motion: animation.morph.resize, clipping: content)
            OverlayMotion.relayoutContent(content, motion: animation.content)
            try? await Task.sleep(for: .seconds((resize + Self.holdResized) * slowdown))
            guard self.generation == token else { return }
            OverlayMotion.hideContent(content, motion: animation.content)
            let duration = backdrop.morph(from: backdrop.visibleShape ?? .open(body: body(Self.secondSize)), to: closed,
                                          motion: animation.morph.close, clipping: content)
            let fadeStart = notch == nil ? 0 : duration * 0.55
            OverlayMotion.fadeOut(panel, after: fadeStart, over: duration - fadeStart, slowdown: slowdown)
            try? await Task.sleep(for: .seconds(duration * slowdown))
            guard self.generation == token else { return }
            self.stop()
        }
        return (open + Self.holdOpen + resize + Self.holdResized + close) * slowdown
    }

    func stop() {
        generation = UUID()
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Stand-in content for previews: a header, a list and a picture, arranged like the
/// window list so the cascade and the blur read as they do in the overlay.
final class PreviewContentView: NSView {
    private let notchHeight: CGFloat
    private var pieces: [NSView] = []

    init(frame: CGRect, notchHeight: CGFloat) {
        self.notchHeight = notchHeight
        super.init(frame: frame)
        wantsLayer = true
        for kind in PreviewContentLayout.kinds {
            let piece = NSView()
            piece.wantsLayer = true
            piece.layer?.backgroundColor = kind.color
            piece.layer?.cornerRadius = kind.radius
            piece.layer?.cornerCurve = .continuous
            addSubview(piece)
            pieces.append(piece)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        for (piece, rect) in zip(pieces, PreviewContentLayout.frames(in: bounds, notchHeight: notchHeight)) {
            piece.frame = rect
        }
    }
}

/// Where the stand-in content's pieces go, for both the view above and the Studio's
/// layer-drawn preview.
enum PreviewContentLayout {
    struct Kind {
        let color: CGColor
        let radius: CGFloat
    }

    static let bar = Kind(color: NSColor(white: 1, alpha: 0.16).cgColor, radius: 5)
    static let row = Kind(color: NSColor(white: 1, alpha: 0.1).cgColor, radius: 9)
    static let picture = Kind(color: NSColor(srgbRed: 0.27, green: 0.42, blue: 0.68, alpha: 1).cgColor, radius: 12)
    /// Top to bottom: two header pills, four rows, the picture.
    static let kinds: [Kind] = [bar, bar, row, row, row, row, picture]

    static func frames(in bounds: CGRect, notchHeight: CGFloat) -> [CGRect] {
        let inset: CGFloat = 18
        let top = bounds.maxY - max(notchHeight, 24) - 12
        let listWidth = min(220, bounds.width * 0.34)
        var frames = [
            CGRect(x: bounds.minX + inset, y: top - 14, width: 90, height: 14),
            CGRect(x: bounds.maxX - inset - 60, y: top - 14, width: 60, height: 14),
        ]
        for index in 0..<4 {
            frames.append(CGRect(x: bounds.minX + inset, y: top - 30 - CGFloat(index + 1) * 50,
                                 width: listWidth, height: 42))
        }
        let pictureLeft = bounds.minX + inset * 2 + listWidth
        frames.append(CGRect(x: pictureLeft, y: bounds.minY + inset, width: bounds.maxX - inset - pictureLeft,
                             height: top - 30 - bounds.minY - inset))
        return frames
    }
}
