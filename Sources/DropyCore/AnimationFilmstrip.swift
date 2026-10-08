import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An animation drawn as a picture: each motion as a strip of frames with its curves
/// beside it, and the content's timing. AI agents look at this (`Dropy animation
/// render`) to see what they wrote; it needs no window server.
public enum AnimationFilmstrip {
    /// The top of a screen as the frames show it, in points (origin bottom left).
    static let stage = CGSize(width: 900, height: 560)
    static let notch = CGSize(width: 200, height: 32)
    static let openSize = CGSize(width: 640, height: 400)
    static let resizedSize = CGSize(width: 760, height: 470)

    static let frameCount = 8
    static let cell = CGSize(width: 140, height: 87)
    static let gap: CGFloat = 8
    static let margin: CGFloat = 24
    static let plotSize = CGSize(width: 300, height: 110)

    /// The picture as PNG data.
    public static func png(for animation: DropyAnimation) -> Data? {
        guard let image = image(for: animation) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    public static func image(for animation: DropyAnimation) -> CGImage? {
        let stripWidth = CGFloat(frameCount) * (cell.width + gap) - gap
        let width = margin * 2 + stripWidth + 24 + plotSize.width
        let rowHeight: CGFloat = 26 + max(cell.height + 18, plotSize.height) + 18
        let height = margin * 2 + 64 + rowHeight * 3 + 96
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(Palette.background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Header: name, summary, timings and cost.
        var y = height - margin
        text(animation.name, at: CGPoint(x: margin, y: y - 22), size: 20, weight: .bold, color: Palette.text, in: context)
        let timings = DropyAnimation.Part.allCases.map { "\($0.title) \(seconds(animation[$0].duration))" }.joined(separator: " · ")
        let cost = animation.cost
        text("\(timings) · \(cost.level.title) (\(cost.reason))", at: CGPoint(x: margin, y: y - 42), size: 12,
             color: Palette.secondary, in: context)
        if !animation.summary.isEmpty {
            text(animation.summary, at: CGPoint(x: margin, y: y - 60), size: 12, color: Palette.secondary, in: context)
        }
        y -= 64

        let notchStart = NotchShape.notch(size: notch, in: stage)
        let open = NotchShape.open(body: body(openSize))
        let resized = NotchShape.open(body: body(resizedSize))
        let rows: [(DropyAnimation.Part, NotchShape, NotchShape)] = [
            (.open, notchStart, open), (.resize, open, resized), (.close, resized, notchStart),
        ]
        for (part, start, end) in rows {
            let motion = animation.morph[keyPath: keyPath(part)]
            text("\(part.title)  \(seconds(motion.duration))\(caption(part, motion))", at: CGPoint(x: margin, y: y - 18),
                 size: 13, weight: .semibold, color: Palette.text, in: context)
            let top = y - 26
            let progress = played(motion)
            for index in 0..<frameCount {
                let time = motion.duration * Double(index) / Double(frameCount - 1)
                let (p, q) = progress(time)
                let shape = NotchMorph.shape(from: start, to: end, widthProgress: p, heightProgress: q)
                let frame = CGRect(x: margin + CGFloat(index) * (cell.width + gap), y: top - cell.height,
                                   width: cell.width, height: cell.height)
                drawFrame(shape, content: contentOpacity(part, animation.content, at: time), in: frame, context: context)
                text(seconds(time), at: CGPoint(x: frame.minX, y: frame.minY - 14), size: 10, color: Palette.secondary, in: context)
            }
            let plot = CGRect(x: margin + stripWidth + 24, y: top - plotSize.height, width: plotSize.width, height: plotSize.height)
            drawPlot(motion, played: progress, in: plot, context: context)
            y -= rowHeight
        }

        // Content timing.
        text("Content", at: CGPoint(x: margin, y: y - 18), size: 13, weight: .semibold, color: Palette.text, in: context)
        let c = animation.content
        let lines = [
            "Reveal: starts \(seconds(c.revealDelay)) after the outline, takes \(seconds(c.revealDuration)), curve \(curveName(c.revealCurve)); pieces cascade over \(seconds(c.staggerSpan)) and drift \(JSONText.format(Double(c.staggerDrift))) pt.",
            "From \(Int((Double(c.restScale) * 100).rounded())) % size\(c.blurRadius > 0 ? " and a \(JSONText.format(Double(c.blurRadius))) pt blur" : ", no blur"). Hide: \(seconds(c.hideDuration)), curve \(curveName(c.hideCurve)). After a resize the new layout fades up over \(seconds(c.relayoutDuration)).",
        ]
        for (index, line) in lines.enumerated() {
            text(line, at: CGPoint(x: margin, y: y - 40 - CGFloat(index) * 18), size: 12, color: Palette.secondary, in: context)
        }
        text("Width (and the ears) in red, height (and the lower corners) in blue. 0 is where a motion starts, 1 where it ends.",
             at: CGPoint(x: margin, y: margin - 4), size: 11, color: Palette.tertiary, in: context)
        return context.makeImage()
    }

    // MARK: Pieces

    private static func keyPath(_ part: DropyAnimation.Part) -> KeyPath<NotchMorph.Motions, NotchMorph.Motion> {
        switch part {
        case .open: \.open
        case .resize: \.resize
        case .close: \.close
        }
    }

    private static func body(_ size: CGSize) -> CGRect {
        CGRect(x: (stage.width - size.width) / 2, y: stage.height - size.height, width: size.width, height: size.height)
    }

    /// The motion's progress as the overlay plays it (forward-only when monotonic).
    static func played(_ motion: NotchMorph.Motion) -> (TimeInterval) -> (Double, Double) {
        // Forward-only depends on the path so far; sample it finely from the start.
        { time in
            var previous: (width: Double, height: Double)?
            if motion.isMonotonic {
                var t = 0.0
                while t < time {
                    previous = motion.progress(at: t, after: previous)
                    t += 1.0 / 240
                }
            }
            let value = motion.progress(at: time, after: previous)
            return (value.width, value.height)
        }
    }

    private static func caption(_ part: DropyAnimation.Part, _ motion: NotchMorph.Motion) -> String {
        let extent = motion.extent
        var notes: [String] = []
        if extent.upperBound > 1.002 { notes.append("overshoots \(Int(((extent.upperBound - 1) * 100).rounded())) %") }
        if extent.lowerBound < -0.002 { notes.append("pulls back \(Int((-extent.lowerBound * 100).rounded())) %") }
        if part == .close { notes.append("forward-only") }
        return notes.isEmpty ? "" : " · " + notes.joined(separator: " · ")
    }

    private static func contentOpacity(_ part: DropyAnimation.Part, _ content: ContentMotion, at time: TimeInterval) -> Double {
        switch part {
        case .open: content.revealOpacity(at: time)
        case .resize: content.relayoutDuration > 0 ? min(max((time - 0.04) / content.relayoutDuration, 0), 1) : 1
        case .close: 1 - TimingCurve.easeIn.value(at: min(max(time / max(content.hideDuration, 0.01), 0), 1))
        }
    }

    private static func drawFrame(_ shape: NotchShape, content: Double, in frame: CGRect, context: CGContext) {
        context.saveGState()
        let clip = CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(clip)
        context.clip()
        context.setFillColor(Palette.desktop)
        context.fill(frame)
        let scale = frame.width / stage.width
        context.translateBy(x: frame.minX, y: frame.minY)
        context.scaleBy(x: scale, y: scale)
        // Menu bar with a few items either side of the notch.
        context.setFillColor(Palette.menuBar)
        context.fill(CGRect(x: 0, y: stage.height - notch.height, width: stage.width, height: notch.height))
        context.setFillColor(Palette.menuItem)
        for x in [30.0, 90, 150, 650, 720, 790, 840] {
            context.fill(CGRect(x: x, y: stage.height - notch.height / 2 - 5, width: 40, height: 10))
        }
        // The outline, its content clipped to it, and its hairline.
        context.addPath(shape.fillPath)
        context.setFillColor(Palette.outline)
        context.fillPath()
        if content > 0.01 {
            context.saveGState()
            context.addPath(shape.fillPath)
            context.clip()
            let body = CGRect(x: (stage.width - openSize.width) / 2, y: stage.height - openSize.height,
                              width: openSize.width, height: openSize.height)
            let inner = shape.body.width > openSize.width ? shape.body : body
            context.setAlpha(CGFloat(content))
            context.setFillColor(Palette.content)
            let rowWidth = inner.width * 0.34
            for row in 0..<4 {
                let rect = CGRect(x: inner.minX + 28, y: inner.maxY - notch.height - 40 - CGFloat(row) * 54,
                                  width: rowWidth, height: 38)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
                context.fillPath()
            }
            let preview = CGRect(x: inner.minX + 56 + rowWidth, y: inner.minY + 28,
                                 width: inner.width - rowWidth - 84, height: inner.height - notch.height - 60)
            context.setFillColor(Palette.preview)
            context.addPath(CGPath(roundedRect: preview, cornerWidth: 12, cornerHeight: 12, transform: nil))
            context.fillPath()
            context.restoreGState()
        }
        context.addPath(shape.strokePath)
        context.setStrokeColor(Palette.hairline)
        context.setLineWidth(1 / scale)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawPlot(_ motion: NotchMorph.Motion, played: (TimeInterval) -> (Double, Double),
                                 in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setFillColor(Palette.desktop)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.fillPath()
        let duration = max(motion.duration, 0.05)
        let low = min(0, motion.extent.lowerBound) - 0.1
        let high = max(1, motion.extent.upperBound) + 0.1
        let inset = rect.insetBy(dx: 10, dy: 10)
        func point(_ time: Double, _ value: Double) -> CGPoint {
            CGPoint(x: inset.minX + inset.width * time / duration,
                    y: inset.minY + inset.height * (value - low) / (high - low))
        }
        context.setStrokeColor(Palette.grid)
        context.setLineWidth(1)
        for value in [0.0, 1.0] {
            context.move(to: point(0, value))
            context.addLine(to: point(duration, value))
        }
        context.strokePath()
        text("1", at: CGPoint(x: rect.minX + 2, y: point(0, 1).y - 4), size: 9, color: Palette.tertiary, in: context)
        text("0", at: CGPoint(x: rect.minX + 2, y: point(0, 0).y - 4), size: 9, color: Palette.tertiary, in: context)
        for (channel, color) in [(1, Palette.height), (0, Palette.width)] {
            context.setStrokeColor(color)
            context.setLineWidth(2)
            for step in 0...120 {
                let time = duration * Double(step) / 120
                let value = played(time)
                let p = point(time, channel == 0 ? value.0 : value.1)
                if step == 0 { context.move(to: p) } else { context.addLine(to: p) }
            }
            context.strokePath()
        }
        context.restoreGState()
    }

    private static func curveName(_ curve: TimingCurve) -> String {
        TimingCurve.named.first { $0.curve == curve }?.name
            ?? "[\(curve.controlPoints.map(JSONText.format).joined(separator: ", "))]"
    }

    private static func seconds(_ value: Double) -> String { "\(JSONText.format((value * 100).rounded() / 100)) s" }

    private enum Weight { case regular, semibold, bold }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat, weight: Weight = .regular,
                             color: CGColor, in context: CGContext) {
        let base = CTFontCreateUIFontForLanguage(weight == .regular ? .system : .emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): base,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private enum Palette {
        static let background = CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        static let desktop = CGColor(srgbRed: 0.2, green: 0.22, blue: 0.27, alpha: 1)
        static let menuBar = CGColor(srgbRed: 0.27, green: 0.29, blue: 0.34, alpha: 1)
        static let menuItem = CGColor(srgbRed: 0.45, green: 0.47, blue: 0.52, alpha: 1)
        static let outline = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        static let hairline = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18)
        static let content = CGColor(srgbRed: 0.32, green: 0.33, blue: 0.36, alpha: 1)
        static let preview = CGColor(srgbRed: 0.24, green: 0.36, blue: 0.56, alpha: 1)
        static let grid = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
        static let width = CGColor(srgbRed: 0.94, green: 0.38, blue: 0.38, alpha: 1)
        static let height = CGColor(srgbRed: 0.42, green: 0.64, blue: 1, alpha: 1)
        static let text = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)
        static let secondary = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6)
        static let tertiary = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.4)
    }
}
