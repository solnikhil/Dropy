import CoreGraphics
import Foundation

/// Tells a deliberate hover at the notch from the pointer passing by.
///
/// The base and both shoulders use the same dwell and drift limits.
/// NotchHoverSession restarts intent when the pointer changes regions or moves
/// beyond the drift limit, so resting after movement can still open the overlay.
public enum HoverIntent {
    /// How long the pointer rests before the overlay opens.
    public static let delay: TimeInterval = 0.22
    /// Sideways travel since entering that still counts as resting.
    public static let maxDrift: CGFloat = 24
    /// After a close, the notch stays quiet this long and until the pointer has left
    /// the zone, so a close cannot turn straight into another opening.
    public static let rearmDelay: TimeInterval = 0.4

}
