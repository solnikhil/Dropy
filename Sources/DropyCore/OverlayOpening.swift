import Foundation

/// A missing Space snapshot is common while WindowServer announces a virtual
/// display. It is not evidence that the person changed desktops.
public struct OverlayDesktopTracker: Sendable {
    public private(set) var spaceID: UInt64?
    public init(spaceID: UInt64? = nil) { self.spaceID = spaceID }

    /// True only for a change between two known desktops on the overlay's display.
    public mutating func observe(_ space: UInt64?) -> Bool {
        guard let space else { return false }
        let previous = spaceID
        spaceID = space
        return previous.map { $0 != space } ?? false
    }
}

public struct OverlayLocation: Equatable, Sendable {
    public let displayID: UInt32
    public let spaceID: UInt64?
    public init(displayID: UInt32, spaceID: UInt64?) {
        self.displayID = displayID
        self.spaceID = spaceID
    }
}

public enum OverlayOpeningAction: Equatable, Sendable {
    case open, close, relocate

    /// An overlay left on a different desktop must open here on the first press.
    /// Unknown Space facts never invent a desktop transition.
    public static func resolve(isOpen: Bool, opened: OverlayLocation?, requested: OverlayLocation?) -> Self {
        guard isOpen else { return .open }
        guard let opened, let requested else { return .close }
        if opened.displayID != requested.displayID { return .relocate }
        if let old = opened.spaceID, let new = requested.spaceID, old != new { return .relocate }
        return .close
    }
}
