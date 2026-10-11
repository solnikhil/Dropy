import CoreGraphics

/// The overlay's outline: a body hanging from the top edge of the screen, with
/// rounded lower corners and concave "ears" where it meets the top edge, the way the
/// camera housing itself meets the menu bar. At its smallest it is the notch; the
/// overlay morphs between the two.
///
/// At a side edge the same outline is turned to face into the screen. In a bottom
/// corner the body is flush with two edges: one ear on each, and one rounded corner
/// facing the middle of the screen.
///
/// Every outline at one position has the same elements in the same order, whatever
/// its size, so Core Animation can interpolate one path into another point by point.
public struct NotchShape: Equatable, Sendable {
    /// The body, in the drawing view's coordinates (origin at the bottom left, as
    /// AppKit draws). The sides `position` names lie on the screen's edges.
    public var body: CGRect
    /// The rounded corners away from the screen edge (the lower ones at the notch).
    public var bottomRadius: CGFloat
    /// How far the concave joins reach out beside the body along the screen edge.
    public var earRadius: CGFloat
    public var position: OverlayPosition

    public init(body: CGRect, bottomRadius: CGFloat, earRadius: CGFloat, position: OverlayPosition = .notch) {
        self.body = body
        self.bottomRadius = bottomRadius
        self.earRadius = earRadius
        self.position = position
    }

    /// Circle-approximating control distance for a cubic Bézier quarter arc.
    static let kappa: CGFloat = 0.5523
    /// Continuous ("squircle") lower corners, as Apple draws its own: each corner
    /// starts this many radii from the vertex and its control points sit close to the
    /// vertex, so the curve eases out of the straight edge instead of bending at once
    /// as a circular arc does.
    static let cornerSpan: CGFloat = 1.35
    static let cornerControl: CGFloat = 0.3

    /// The filled outline, closed along the screen edge.
    public var fillPath: CGPath { outline(closed: true) }

    /// The same outline without the screen edge, for a hairline that separates the
    /// overlay from what is behind it without drawing along the screen edge.
    public var strokePath: CGPath { outline(closed: false) }

    private func outline(closed: Bool) -> CGPath {
        let path = CGMutablePath()
        switch position {
        case .notch:
            Self.addHangingOutline(to: path, body: body, bottomRadius: bottomRadius, earRadius: earRadius)
            if closed { path.closeSubpath() }
            return path
        case .left, .right:
            // Drawn hanging from a top edge at y = 0, then turned onto the side edge:
            // along the edge is the hanging outline's width, away from it its height.
            Self.addHangingOutline(to: path, body: CGRect(x: 0, y: -body.width, width: body.height, height: body.width),
                                   bottomRadius: bottomRadius, earRadius: earRadius)
            if closed { path.closeSubpath() }
            var turn = position == .left
                ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: body.minX, ty: body.minY)
                : CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: body.maxX, ty: body.maxY)
            return path.copy(using: &turn) ?? path
        case .bottomLeft, .bottomRight:
            // Drawn in a bottom-left corner at the origin, mirrored for the right.
            Self.addCornerOutline(to: path, size: body.size, radius: bottomRadius, ear: earRadius)
            if closed {
                path.addLine(to: .zero)
                path.closeSubpath()
            }
            var place = position == .bottomLeft
                ? CGAffineTransform(translationX: body.minX, y: body.minY)
                : CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: body.maxX, ty: body.minY)
            return path.copy(using: &place) ?? path
        }
    }

    private static func addHangingOutline(to path: CGMutablePath, body: CGRect, bottomRadius: CGFloat, earRadius: CGFloat) {
        let left = body.minX, right = body.maxX, top = body.maxY, bottom = body.minY
        // Corners never exceed what the body can hold, so a tiny shape stays well formed.
        let radius = max(0, min(bottomRadius * cornerSpan, body.width / 2, body.height / 2))
        let ear = max(0, min(earRadius, body.height - radius))
        let k = kappa
        let c = cornerControl
        path.move(to: CGPoint(x: left - ear, y: top))
        // Left ear: from the top edge, curving down into the body's side.
        path.addCurve(to: CGPoint(x: left, y: top - ear),
                      control1: CGPoint(x: left - ear * (1 - k), y: top),
                      control2: CGPoint(x: left, y: top - ear * k))
        path.addLine(to: CGPoint(x: left, y: bottom + radius))
        path.addCurve(to: CGPoint(x: left + radius, y: bottom),
                      control1: CGPoint(x: left, y: bottom + radius * c),
                      control2: CGPoint(x: left + radius * c, y: bottom))
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addCurve(to: CGPoint(x: right, y: bottom + radius),
                      control1: CGPoint(x: right - radius * c, y: bottom),
                      control2: CGPoint(x: right, y: bottom + radius * c))
        path.addLine(to: CGPoint(x: right, y: top - ear))
        path.addCurve(to: CGPoint(x: right + ear, y: top),
                      control1: CGPoint(x: right, y: top - ear * k),
                      control2: CGPoint(x: right + ear * (1 - k), y: top))
    }

    /// A body of `size` in the corner where the left edge (x = 0) meets the bottom
    /// edge (y = 0): an ear on the left edge above it, the rounded corner opposite the
    /// screen corner, and an ear on the bottom edge beside it.
    private static func addCornerOutline(to path: CGMutablePath, size: CGSize, radius cornerRadius: CGFloat, ear earRadius: CGFloat) {
        let w = size.width, h = size.height
        let radius = max(0, min(cornerRadius * cornerSpan, w / 2, h / 2))
        let ear = max(0, min(earRadius, h - radius, w - radius))
        let k = kappa
        let c = cornerControl
        path.move(to: CGPoint(x: 0, y: h + ear))
        // Ear on the left edge: curving from the edge into the body's top side.
        path.addCurve(to: CGPoint(x: ear, y: h),
                      control1: CGPoint(x: 0, y: h + ear * (1 - k)),
                      control2: CGPoint(x: ear * k, y: h))
        path.addLine(to: CGPoint(x: w - radius, y: h))
        path.addCurve(to: CGPoint(x: w, y: h - radius),
                      control1: CGPoint(x: w - radius * c, y: h),
                      control2: CGPoint(x: w, y: h - radius * c))
        path.addLine(to: CGPoint(x: w, y: ear))
        // Ear on the bottom edge.
        path.addCurve(to: CGPoint(x: w + ear, y: 0),
                      control1: CGPoint(x: w, y: ear * k),
                      control2: CGPoint(x: w + ear * (1 - k), y: 0))
    }

    /// The same outline moved by (dx, dy): for when the window that draws it moves
    /// but the outline must stay put on screen.
    public func offsetBy(dx: CGFloat, dy: CGFloat) -> NotchShape {
        NotchShape(body: body.offsetBy(dx: dx, dy: dy), bottomRadius: bottomRadius, earRadius: earRadius, position: position)
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

    /// The open overlay around `body`, whose sides at `position` are screen edges.
    public static func open(body: CGRect, at position: OverlayPosition = .notch) -> NotchShape {
        NotchShape(body: body, bottomRadius: 26, earRadius: openEarRadius, position: position)
    }

    /// Where an overlay opening from a side edge or a corner starts and ends: a small
    /// nub on the edge, centered on the open `body` (or in its corner). There is no
    /// housing to grow out of there, so the overlay also fades as it grows.
    public static func nub(for body: CGRect, at position: OverlayPosition) -> NotchShape {
        let along: CGFloat = 140, depth: CGFloat = 10, corner: CGFloat = 28
        let rect: CGRect
        switch position {
        case .notch:
            rect = CGRect(x: body.midX - along / 2, y: body.maxY - depth, width: along, height: depth)
        case .left:
            rect = CGRect(x: body.minX, y: body.midY - along / 2, width: depth, height: along)
        case .right:
            rect = CGRect(x: body.maxX - depth, y: body.midY - along / 2, width: depth, height: along)
        case .bottomLeft:
            rect = CGRect(x: body.minX, y: body.minY, width: corner, height: corner)
        case .bottomRight:
            rect = CGRect(x: body.maxX - corner, y: body.minY, width: corner, height: corner)
        }
        return NotchShape(body: rect, bottomRadius: position.isCorner ? 10 : 4, earRadius: 3, position: position)
    }
}
