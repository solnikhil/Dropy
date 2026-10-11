import CoreGraphics

/// Where on the screen the overlay opens from. At the notch it hangs from the top
/// edge; at a side edge it is the same outline turned to face into the screen; in a
/// bottom corner it sits flush with both edges, with one rounded corner facing the
/// middle of the screen. Every animation plays at every position: "width" is always
/// along the edge (horizontal in a corner) and "height" away from it.
public enum OverlayPosition: String, Codable, CaseIterable, Sendable {
    case notch
    case left
    case right
    case bottomLeft
    case bottomRight

    public var title: String {
        switch self {
        case .notch: "Notch"
        case .left: "Left edge"
        case .right: "Right edge"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }

    public var isCorner: Bool { self == .bottomLeft || self == .bottomRight }

    /// The body of `size` on `screen` (AppKit coordinates). A side edge centers it in
    /// the space between the menu bar and the Dock (`visible`) when it fits there.
    public func body(size: CGSize, screen: CGRect, visible: CGRect) -> CGRect {
        let width = min(size.width, screen.width), height = min(size.height, screen.height)
        let x: CGFloat
        switch self {
        case .notch: x = screen.midX - width / 2
        case .left, .bottomLeft: x = screen.minX
        case .right, .bottomRight: x = screen.maxX - width
        }
        let y: CGFloat
        switch self {
        case .notch: y = screen.maxY - height
        case .bottomLeft, .bottomRight: y = screen.minY
        case .left, .right:
            let area = visible.intersection(screen).isNull ? screen : visible.intersection(screen)
            y = height <= area.height
                ? min(max(area.midY - height / 2, area.minY), area.maxY - height)
                : max(screen.minY, area.maxY - height)
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `body` grown until it is flush with this position's screen edges, for a body
    /// laid out around a window that sits wherever macOS put it.
    public func reachingEdges(_ body: CGRect, screen: CGRect) -> CGRect {
        var minX = body.minX, maxX = body.maxX, minY = body.minY, maxY = body.maxY
        switch self {
        case .notch: maxY = screen.maxY
        case .left: minX = screen.minX
        case .right: maxX = screen.maxX
        case .bottomLeft: minX = screen.minX; minY = screen.minY
        case .bottomRight: maxX = screen.maxX; minY = screen.minY
        }
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    /// The overlay window around `body`, with `margin` for the outline's overshoot on
    /// every side that is not a screen edge.
    public func canvas(around body: CGRect, margin: CGFloat, screen: CGRect) -> CGRect {
        let grown = body.insetBy(dx: -margin, dy: -margin)
        let clipped = grown.intersection(screen)
        return clipped.isNull ? grown : clipped
    }

    /// The point content grows from, as a fraction of its bounds (origin bottom left).
    public var growthAnchor: CGPoint {
        switch self {
        case .notch: CGPoint(x: 0.5, y: 1)
        case .left: CGPoint(x: 0, y: 0.5)
        case .right: CGPoint(x: 1, y: 0.5)
        case .bottomLeft: CGPoint(x: 0, y: 0)
        case .bottomRight: CGPoint(x: 1, y: 0)
        }
    }

    /// The direction content drifts in from (a unit vector, origin bottom left): at
    /// the notch pieces start above their place and fall into it.
    public var driftDirection: CGVector {
        let diagonal = 1 / 2.squareRoot()
        switch self {
        case .notch: return CGVector(dx: 0, dy: 1)
        case .left: return CGVector(dx: -1, dy: 0)
        case .right: return CGVector(dx: 1, dy: 0)
        case .bottomLeft: return CGVector(dx: -diagonal, dy: -diagonal)
        case .bottomRight: return CGVector(dx: diagonal, dy: -diagonal)
        }
    }

    /// Pieces arrive in order from the edge they grow out of: top first at the notch
    /// and the side edges (reading order), bottom first in a corner.
    public var cascadesFromBottom: Bool { isCorner }
}
