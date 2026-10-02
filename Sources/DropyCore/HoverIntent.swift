import CoreGraphics
import Foundation

/// Tells a deliberate hover at the notch from the pointer passing by.
///
/// A person who wants the overlay pushes the pointer up under the notch and leaves it
/// there; a pointer on its way somewhere else crosses the zone sideways. The hover
/// opens only if, after the delay, the pointer is still in the zone and has not
/// travelled far sideways since it entered.
public enum HoverIntent {
    /// How long the pointer rests before the overlay opens.
    public static let delay: TimeInterval = 0.22
    /// Sideways travel since entering that still counts as resting.
    public static let maxDrift: CGFloat = 24
    /// After a close, the notch stays quiet this long and until the pointer has left
    /// the zone, so a close cannot turn straight into another opening.
    public static let rearmDelay: TimeInterval = 0.4

    public static func confirms(enteredAt entry: CGPoint, now point: CGPoint, zone: CGRect) -> Bool {
        zone.contains(point) && abs(point.x - entry.x) <= maxDrift
    }
}
