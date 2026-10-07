import CoreGraphics
import Foundation

/// Where Dropy's Stage display sits, where windows wait on it, and how the pointer
/// maps between the overlay and the Stage. All rectangles are global top-left
/// coordinates (CoreGraphics display bounds, Accessibility), unless a name says AppKit.
public enum StageGeometry {
    /// Space kept around a waiting window: below the Stage's own menu bar, and away
    /// from its edges, where the Dock or a hot corner could react to the pointer.
    public static let margin: CGFloat = 40

    /// The Stage's size in points: the notch display's size, so any window that fits
    /// the overlay fits the Stage. Even numbers keep the 2× backing exact.
    public static func size(for screen: CGSize) -> CGSize {
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded(.down) * 2) }
        return CGSize(width: even(screen.width), height: even(screen.height))
    }

    /// The Stage's top-left: just past the bottom-right corner of every real display,
    /// so it touches them at a single corner point and the pointer can reach it only
    /// diagonally (measured: macOS keeps this arrangement).
    public static func origin(displays: [CGRect]) -> CGPoint {
        guard let first = displays.first else { return .zero }
        let union = displays.dropFirst().reduce(first) { $0.union($1) }
        return CGPoint(x: union.maxX, y: union.maxY)
    }

    /// Where a window of `size` waits on the Stage: inside the margins, below the
    /// Stage's menu bar. A window larger than the room left is pinned to that corner.
    public static func slot(for size: CGSize, stage: CGRect, menuBarHeight: CGFloat) -> CGPoint {
        CGPoint(x: stage.minX + margin, y: stage.minY + menuBarHeight + margin)
    }

    /// Maps `point` from rectangle `from` to the same relative spot in `to`.
    public static func map(_ point: CGPoint, from: CGRect, to: CGRect) -> CGPoint {
        guard from.width > 0, from.height > 0 else { return CGPoint(x: to.midX, y: to.midY) }
        return CGPoint(x: to.minX + (point.x - from.minX) / from.width * to.width,
                       y: to.minY + (point.y - from.minY) / from.height * to.height)
    }

    /// The closest point to `point` that lies on one of `displays`, for a pointer that
    /// wandered onto the Stage.
    public static func nearestPoint(to point: CGPoint, on displays: [CGRect]) -> CGPoint {
        var best = point
        var bestDistance = CGFloat.infinity
        for display in displays where display.width > 0 && display.height > 0 {
            let clamped = CGPoint(x: min(max(point.x, display.minX), display.maxX - 1),
                                  y: min(max(point.y, display.minY), display.maxY - 1))
            let distance = hypot(clamped.x - point.x, clamped.y - point.y)
            if distance < bestDistance {
                bestDistance = distance
                best = clamped
            }
        }
        return best
    }
}
