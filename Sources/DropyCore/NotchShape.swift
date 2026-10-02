import CoreGraphics

/// The overlay's outline: a body hanging from the top edge of the screen, with
/// rounded lower corners and concave "ears" where it meets the top edge, the way the
/// camera housing itself meets the menu bar. At its smallest it is the notch; the
/// overlay morphs between the two.
///
/// Every outline has the same elements in the same order, whatever its size, so Core
/// Animation can interpolate one path into another point by point.
public struct NotchShape: Equatable, Sendable {
    /// The body below the top edge, in the drawing view's coordinates (origin at the
    /// bottom left, as AppKit draws). Its top is the screen's top edge.
    public var body: CGRect
    public var bottomRadius: CGFloat
    /// How far the concave joins reach out beside the body along the top edge.
    public var earRadius: CGFloat

    public init(body: CGRect, bottomRadius: CGFloat, earRadius: CGFloat) {
        self.body = body
        self.bottomRadius = bottomRadius
        self.earRadius = earRadius
    }

    /// Circle-approximating control distance for a cubic Bézier quarter arc.
    static let kappa: CGFloat = 0.5523

    /// The filled outline, closed along the top edge.
    public var fillPath: CGPath {
        let path = CGMutablePath()
        addOutline(to: path)
        path.closeSubpath()
        return path
    }

    /// The same outline without the top edge, for a hairline that separates the
    /// overlay from what is behind it without drawing along the screen edge.
    public var strokePath: CGPath {
        let path = CGMutablePath()
        addOutline(to: path)
        return path
    }

    private func addOutline(to path: CGMutablePath) {
        let left = body.minX, right = body.maxX, top = body.maxY, bottom = body.minY
        // Radii never exceed what the body can hold, so a tiny shape stays well formed.
        let radius = max(0, min(bottomRadius, body.width / 2, body.height / 2))
        let ear = max(0, min(earRadius, body.height - radius))
        let k = Self.kappa
        path.move(to: CGPoint(x: left - ear, y: top))
        // Left ear: from the top edge, curving down into the body's side.
        path.addCurve(to: CGPoint(x: left, y: top - ear),
                      control1: CGPoint(x: left - ear * (1 - k), y: top),
                      control2: CGPoint(x: left, y: top - ear * k))
        path.addLine(to: CGPoint(x: left, y: bottom + radius))
        path.addCurve(to: CGPoint(x: left + radius, y: bottom),
                      control1: CGPoint(x: left, y: bottom + radius * (1 - k)),
                      control2: CGPoint(x: left + radius * (1 - k), y: bottom))
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addCurve(to: CGPoint(x: right, y: bottom + radius),
                      control1: CGPoint(x: right - radius * (1 - k), y: bottom),
                      control2: CGPoint(x: right, y: bottom + radius * (1 - k)))
        path.addLine(to: CGPoint(x: right, y: top - ear))
        path.addCurve(to: CGPoint(x: right + ear, y: top),
                      control1: CGPoint(x: right, y: top - ear * k),
                      control2: CGPoint(x: right + ear * (1 - k), y: top))
    }

    /// The camera housing as the overlay's starting point: `notchSize` centered at the
    /// top of a `canvas` (the overlay window's size).
    public static func notch(size notchSize: CGSize, in canvas: CGSize) -> NotchShape {
        NotchShape(body: CGRect(x: (canvas.width - notchSize.width) / 2, y: canvas.height - notchSize.height,
                                width: notchSize.width, height: notchSize.height),
                   bottomRadius: min(10, notchSize.height / 3), earRadius: 4)
    }

    /// Ear reach of the open overlay.
    public static let openEarRadius: CGFloat = 14

    /// The open overlay around `body`, whose top is the top edge.
    public static func open(body: CGRect) -> NotchShape {
        NotchShape(body: body, bottomRadius: 26, earRadius: openEarRadius)
    }
}
