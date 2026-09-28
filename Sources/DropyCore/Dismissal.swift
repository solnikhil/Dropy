import Foundation

/// Something that may end an overlay session.
public enum DismissEvent: Sendable {
    /// Esc, or the global shortcut pressed while the overlay is open.
    case escape
    /// A click that lands outside the overlay panel.
    case clickOutside
    /// The pointer left the panel after having been inside it.
    case pointerLeft
}

extension DismissBehavior {
    /// Esc always closes. Pointer-leave also closes on an outside click, since a
    /// click elsewhere is an even clearer signal than the pointer drifting away.
    public func closes(on event: DismissEvent) -> Bool {
        switch (self, event) {
        case (_, .escape): true
        case (.clickOutside, .clickOutside), (.pointerLeave, .clickOutside): true
        case (.pointerLeave, .pointerLeft): true
        default: false
        }
    }

    /// Delay before a pointer-leave closes, so a brief overshoot does not dismiss.
    public static let pointerLeaveGrace: TimeInterval = 0.35
}
