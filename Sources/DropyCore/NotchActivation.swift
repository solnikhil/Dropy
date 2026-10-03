import Foundation
import CoreGraphics

/// Reachable display space surrounding the camera housing, in the caller's coordinate system.
public struct NotchActivation: Equatable, Sendable {
    public enum Region: Equatable, Sendable { case base, left, right }
    public let housing: CGRect
    public static let reach: CGFloat = 12
    public init(housing: CGRect) { self.housing = housing }
    /// AppKit's bottom-origin coordinates. The housing itself is never a target.
    public func frame(for region: Region) -> CGRect {
        let r = Self.reach
        switch region {
        case .base: return CGRect(x: housing.minX, y: housing.minY - r, width: housing.width, height: r)
        case .left: return CGRect(x: housing.minX - r, y: housing.minY - r, width: r, height: housing.height + r)
        case .right: return CGRect(x: housing.maxX, y: housing.minY - r, width: r, height: housing.height + r)
        }
    }
    /// One continuous tracking surface includes the camera's unreachable interior
    /// so its lower boundary is inside the tracking window, not a window seam.
    public var trackingFrame: CGRect {
        CGRect(x: housing.minX - Self.reach, y: housing.minY - Self.reach,
               width: housing.width + 2 * Self.reach, height: housing.height + Self.reach)
    }
    public func region(at point: CGPoint) -> Region? {
        // The camera interior stays excluded, but its reachable lower edge belongs
        // to the base. CGRect.contains alone excludes that maximum-y boundary.
        if point.x >= housing.minX, point.x < housing.maxX,
           point.y >= housing.minY - Self.reach, point.y <= housing.minY { return .base }
        return [.left, .right].first { frame(for: $0).contains(point) }
    }
}

/// Monotonic-time intent, independent of AppKit events and timer delivery.
public struct NotchHoverSession: Sendable {
    private var region: NotchActivation.Region?
    private var anchor = CGPoint.zero
    public private(set) var deadline: TimeInterval?
    private var quietUntil: TimeInterval = 0
    private var waitingForExit = false
    public init() {}
    public mutating func reset() { region = nil; deadline = nil }
    public mutating func closed(at time: TimeInterval, pointerInside: Bool) {
        reset()
        quietUntil = time + HoverIntent.rearmDelay
        waitingForExit = pointerInside
    }
    /// Returns true once, after a continuous rest in the same region.
    public mutating func sample(point: CGPoint, region next: NotchActivation.Region?, at time: TimeInterval) -> Bool {
        guard let next else { reset(); waitingForExit = false; return false }
        guard !waitingForExit else { reset(); return false }
        if time < quietUntil {
            region = next; anchor = point; deadline = quietUntil + HoverIntent.delay
            return false
        }
        if next != region || abs(point.x - anchor.x) > HoverIntent.maxDrift || abs(point.y - anchor.y) > HoverIntent.maxDrift {
            region = next; anchor = point; deadline = time + HoverIntent.delay
            return false
        }
        if let deadline, time >= deadline { reset(); return true }
        return false
    }
}

/// Experimental cursor barrier in Quartz's top-origin coordinates. Only blocks a
/// crossing of the housing at housing height; movement beneath it stays native.
public enum NotchCursorBarrier {
    public static func constrained(from previous: CGPoint, to point: CGPoint, housing: CGRect) -> CGPoint? {
        guard previous.y >= housing.minY, previous.y < housing.maxY,
              point.y >= housing.minY, point.y < housing.maxY else { return nil }
        if previous.x < housing.minX, point.x >= housing.minX {
            return CGPoint(x: housing.minX - 1, y: point.y)
        }
        if previous.x >= housing.maxX, point.x < housing.maxX {
            return CGPoint(x: housing.maxX + 1, y: point.y)
        }
        return nil
    }
}
