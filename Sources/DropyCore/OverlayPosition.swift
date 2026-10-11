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

    /// What the overlay treats as the screen's edges: the screen, except that a Dock
    /// on the bottom, left or right moves that edge to the Dock's inner side. macOS
    /// draws the Dock above every ordinary window, so a docked app under it would be
    /// covered. A hidden Dock leaves only a few points and is ignored. The top edge is
    /// always the screen's.
    public static func edges(screen: CGRect, visible: CGRect) -> CGRect {
        let area = visible.intersection(screen)
        guard !area.isNull else { return screen }
        func inset(_ gap: CGFloat) -> CGFloat { gap > hiddenDockGap ? gap : 0 }
        let minX = screen.minX + inset(area.minX - screen.minX)
        let maxX = screen.maxX - inset(screen.maxX - area.maxX)
        let minY = screen.minY + inset(area.minY - screen.minY)
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, screen.maxY - minY))
    }

    /// The space an overlay at this position may take: the whole screen at the notch;
    /// beside a side edge, between the menu bar and the Dock; in a corner, everything
    /// clear of the Dock.
    public func room(screen: CGRect, visible: CGRect) -> CGRect {
        let edges = Self.edges(screen: screen, visible: visible)
        switch self {
        case .notch: return screen
        case .bottomLeft, .bottomRight: return edges
        case .left, .right:
            let area = visible.intersection(screen).isNull ? screen : visible.intersection(screen)
            return CGRect(x: edges.minX, y: area.minY, width: edges.width, height: area.height)
        }
    }

    /// The strip macOS keeps for a hidden Dock, at most.
    static let hiddenDockGap: CGFloat = 8

    /// The body of `size` on `screen` (AppKit coordinates), flush with this position's
    /// edges (see `edges`). A side edge centers it in the space between the menu bar
    /// and the Dock (`visible`) when it fits there.
    public func body(size: CGSize, screen: CGRect, visible: CGRect) -> CGRect {
        let edges = Self.edges(screen: screen, visible: visible)
        let room = room(screen: screen, visible: visible)
        let width = min(size.width, room.width), height = min(size.height, room.height)
        let x: CGFloat
        switch self {
        case .notch: x = screen.midX - width / 2
        case .left, .bottomLeft: x = edges.minX
        case .right, .bottomRight: x = edges.maxX - width
        }
        let y: CGFloat
        switch self {
        case .notch: y = screen.maxY - height
        case .bottomLeft, .bottomRight: y = edges.minY
        case .left, .right:
            let area = visible.intersection(screen).isNull ? screen : visible.intersection(screen)
            y = height <= area.height
                ? min(max(area.midY - height / 2, area.minY), area.maxY - height)
                : max(edges.minY, area.maxY - height)
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `body` grown until it is flush with this position's screen edges, for a body
    /// laid out around a window that sits wherever macOS put it.
    public func reachingEdges(_ body: CGRect, screen: CGRect, visible: CGRect? = nil) -> CGRect {
        let edges = Self.edges(screen: screen, visible: visible ?? screen)
        var minX = body.minX, maxX = body.maxX, minY = body.minY, maxY = body.maxY
        switch self {
        case .notch: maxY = screen.maxY
        case .left: minX = edges.minX
        case .right: maxX = edges.maxX
        case .bottomLeft: minX = edges.minX; minY = edges.minY
        case .bottomRight: maxX = edges.maxX; minY = edges.minY
        }
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    /// The overlay window around `body`, with `margin` for the outline's overshoot on
    /// every side that is not a screen edge.
    public func canvas(around body: CGRect, margin: CGFloat, screen: CGRect, visible: CGRect? = nil) -> CGRect {
        let grown = body.insetBy(dx: -margin, dy: -margin)
        // At the notch only the top edge bounds it; elsewhere also the Dock's side.
        let bounds = self == .notch ? screen : Self.edges(screen: screen, visible: visible ?? screen)
        let clipped = grown.intersection(bounds)
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

/// The screen edge the Dock sits on, as the Dock's own "orientation" setting names it.
public enum DockSide: String, Sendable {
    case bottom
    case left
    case right

    /// Unknown or missing values are the Dock's default, the bottom.
    public init(orientation: String?) {
        self = orientation.flatMap(DockSide.init(rawValue:)) ?? .bottom
    }
}

extension OverlayPosition {
    /// Whether the overlay sits on the Dock's edge, where the Dock would be drawn
    /// over a docked app. A side edge with the Dock at the bottom stays between them.
    public func sharesEdge(with dock: DockSide) -> Bool {
        switch (self, dock) {
        case (.bottomLeft, .bottom), (.bottomRight, .bottom), (.left, .left), (.bottomLeft, .left),
             (.right, .right), (.bottomRight, .right): true
        default: false
        }
    }

    /// Whether Dropy should keep the Dock hidden: the person asked for it and the
    /// overlay sits on the Dock's edge.
    public func hidesDock(preference: Bool, dock: DockSide) -> Bool {
        preference && sharesEdge(with: dock)
    }
}

extension DockSide {
    /// `visible` (the screen's visible frame) as it is once the Dock on this side has
    /// hidden: an opening that hides the Dock lays out for the screen it is about to
    /// have, not the one still showing the Dock as it slides away.
    public func visible(_ visible: CGRect, screen: CGRect) -> CGRect {
        var minX = visible.minX, maxX = visible.maxX, minY = visible.minY
        switch self {
        case .bottom: minY = screen.minY
        case .left: minX = screen.minX
        case .right: maxX = screen.maxX
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: visible.maxY - minY)
    }
}
