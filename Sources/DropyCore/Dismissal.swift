import Foundation

/// Something that may end an overlay session.
public enum DismissEvent: Sendable {
    /// Esc, or the global shortcut pressed while the overlay is open.
    case escape
    /// A click that lands outside the overlay panel.
    case clickOutside
    /// The pointer left the panel after having been inside it.
    case pointerLeft
    /// The overlay's display switched to another desktop (a swipe, Control-arrow, or
    /// an app going full screen).
    case desktopChanged
    /// Mission Control, App Exposé or Show Desktop began.
    case missionControl
    /// The Mac is going to sleep, the screen locked or the screen saver started, or
    /// another user took over the screen.
    case sessionEnded
    /// The overlay's display went away or changed size or place.
    case displayChanged

    /// Whether the event is the system taking the screen away rather than the person
    /// dismissing the overlay. Focus is not handed back (activating an app would,
    /// for one, end Mission Control). A pinned monitor may follow a desktop change.
    public var isSystemChange: Bool {
        switch self {
        case .escape, .clickOutside, .pointerLeft: false
        case .desktopChanged, .missionControl, .sessionEnded, .displayChanged: true
        }
    }
}

extension DismissBehavior {
    /// Esc always closes. Pointer-leave also closes on an outside click, since a
    /// click elsewhere is an even clearer signal than the pointer drifting away.
    public func closes(on event: DismissEvent, isPinned: Bool = false) -> Bool {
        // A monitor follows desktops but still yields when the system takes over.
        if isPinned {
            switch event {
            case .clickOutside, .pointerLeft, .desktopChanged: return false
            default: break
            }
        }
        if event.isSystemChange { return true }
        return switch (self, event) {
        case (_, .escape): true
        case (.clickOutside, .clickOutside), (.pointerLeave, .clickOutside): true
        case (.pointerLeave, .pointerLeft): true
        default: false
        }
    }

    /// Delay before a pointer-leave closes, so a brief overshoot does not dismiss.
    public static let pointerLeaveGrace: TimeInterval = 0.35
}
