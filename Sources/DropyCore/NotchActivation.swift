import Foundation
import CoreGraphics

/// Reachable display space surrounding the camera housing, in the caller's coordinate system.
public struct NotchActivation: Equatable, Sendable {
    public enum Region: Equatable, Sendable { case base, left, right }
    public let housing: CGRect
    public static let reach: CGFloat = 12
    public init(housing: CGRect) { self.housing = housing }
    /// AppKit's bottom-origin coordinates.
    public func frame(for region: Region) -> CGRect {
        let r = Self.reach
        switch region {
        case .base: return CGRect(x: housing.minX, y: housing.minY - r, width: housing.width, height: r)
        case .left: return CGRect(x: housing.minX - r, y: housing.minY - r, width: r, height: housing.height + r)
        case .right: return CGRect(x: housing.maxX, y: housing.minY - r, width: r, height: housing.height + r)
        }
    }
    /// The base, the housing and both shoulders as one continuous surface.
    public var trackingFrame: CGRect {
        CGRect(x: housing.minX - Self.reach, y: housing.minY - Self.reach,
               width: housing.width + 2 * Self.reach, height: housing.height + Self.reach)
    }
    /// The housing counts as the base: whether macOS lets the pointer slide under the
    /// camera or holds it at the lower edge, pushing straight up must open. Every
    /// edge is inclusive, so the screen's top row and the housing's lower edge count.
    public func region(at point: CGPoint) -> Region? {
        let r = Self.reach
        guard point.y >= housing.minY - r, point.y <= housing.maxY else { return nil }
        if point.x >= housing.minX, point.x <= housing.maxX { return .base }
        if point.x >= housing.minX - r, point.x < housing.minX { return .left }
        if point.x > housing.maxX, point.x <= housing.maxX + r { return .right }
        return nil
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
        // Only real travel restarts intent. Moving between base and shoulder near a
        // corner is still resting; a pass across the notch exceeds the drift limit.
        if region == nil || abs(point.x - anchor.x) > HoverIntent.maxDrift || abs(point.y - anchor.y) > HoverIntent.maxDrift {
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
