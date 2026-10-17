import Foundation

/// Animation and source placement finish independently. Neither may enable input
/// while the other still uses old geometry; stale completions never unlock a move.
public struct LiveLayoutReadiness: Sendable {
    private var animationReady = true
    private var move: UUID?
    public init() {}
    public var isMoving: Bool { move != nil }
    public var allowsInput: Bool { animationReady && move == nil }
    public mutating func suspendAnimation() { animationReady = false }
    public mutating func resumeAnimation() { animationReady = true }
    public mutating func beginMove(_ revision: UUID) { move = revision }
    public mutating func finishMove(_ revision: UUID) {
        if move == revision { move = nil }
    }
    public mutating func reset() { animationReady = true; move = nil }
}
