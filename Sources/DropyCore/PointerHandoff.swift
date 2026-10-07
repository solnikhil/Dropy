import CoreGraphics
import Foundation

/// Live mode's pointer hand-off. The app's window stays on the Stage and is streamed
/// into the overlay (the cast). When the pointer moves into the cast, the real
/// pointer moves to the matching point on the Stage, so every hover, click, scroll,
/// menu and drag is the app's own; Dropy draws a cursor where the person sees the
/// cast. When the pointer leaves the window on the Stage, it comes back to the
/// matching point just outside the cast. All points are global top-left coordinates.
public struct PointerHandoff: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        /// Nothing to do: the pointer is outside the cast and stays on the real display.
        case none
        /// Move the pointer onto the Stage here, and show Dropy's cursor at `cursor`.
        case enter(stage: CGPoint, cursor: CGPoint)
        /// The pointer is on the Stage; Dropy's cursor goes here.
        case follow(cursor: CGPoint)
        /// Move the pointer back to the real display here and hide Dropy's cursor.
        case leave(screen: CGPoint)
    }

    /// Where the person sees the window, in the overlay.
    public var cast: CGRect
    /// Where the window really is, on the Stage.
    public var staged: CGRect
    public private(set) var onStage = false

    public init(cast: CGRect, staged: CGRect) {
        self.cast = cast
        self.staged = staged
    }

    /// The next step for a pointer that moved to `location`.
    public mutating func pointer(at location: CGPoint) -> Command {
        if onStage {
            if staged.contains(location) {
                return .follow(cursor: StageGeometry.map(location, from: staged, to: cast))
            }
            onStage = false
            return .leave(screen: exitPoint(for: location))
        }
        guard cast.contains(location) else { return .none }
        onStage = true
        return .enter(stage: StageGeometry.map(location, from: cast, to: staged), cursor: location)
    }

    /// The pointer was moved away by something else (the overlay closed, a hot key);
    /// it is no longer Dropy's to follow.
    public mutating func reset() { onStage = false }

    /// The matching point just outside the cast: the same relative spot past the edge
    /// the pointer left by, nudged two points out so the next move does not re-enter.
    func exitPoint(for location: CGPoint) -> CGPoint {
        var point = StageGeometry.map(location, from: staged, to: cast)
        let nudge: CGFloat = 2
        if point.x < cast.minX { point.x = min(point.x, cast.minX - nudge) }
        if point.x >= cast.maxX { point.x = max(point.x, cast.maxX + nudge) }
        if point.y < cast.minY { point.y = min(point.y, cast.minY - nudge) }
        if point.y >= cast.maxY { point.y = max(point.y, cast.maxY + nudge) }
        return point
    }
}
