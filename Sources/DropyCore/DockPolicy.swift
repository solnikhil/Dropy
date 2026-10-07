import CoreGraphics
import Foundation

/// The rules for a docked window that decide when the overlay stays, closes or lets
/// go. Pure, so each is unit-tested; the app supplies what macOS reports.
public enum DockPolicy {
    // MARK: Clicks

    /// One on-screen window under a click, as CGWindowList lists it (front to back).
    public struct WindowAtPoint: Equatable, Sendable {
        public var processID: Int32
        /// Global top-left coordinates.
        public var bounds: CGRect
        public var layer: Int
        public var bundleIdentifier: String?

        public init(processID: Int32, bounds: CGRect, layer: Int, bundleIdentifier: String?) {
            self.processID = processID
            self.bounds = bounds
            self.layer = layer
            self.bundleIdentifier = bundleIdentifier
        }
    }

    /// The menu bar's window level. Its titles belong to the frontmost app, which is
    /// the docked app while the overlay is open.
    public static let menuBarLayer = 24

    /// Whether a click belongs to the docked app session (its window, menus, popovers,
    /// sheets, the menu bar, or system panels it opened) rather than somewhere else.
    /// - Parameters:
    ///   - point: global top-left coordinates.
    ///   - body: the overlay's body in global coordinates; clicks on its border or band count as inside.
    ///   - windows: on-screen windows, front to back.
    public static func clickIsInside(point: CGPoint, body: CGRect, windows: [WindowAtPoint],
                                     ownProcessID: Int32, sourceProcessID: Int32) -> Bool {
        if body.contains(point) { return true }
        guard let hit = windows.first(where: { $0.processID != ownProcessID && $0.bounds.contains(point) }) else {
            return false
        }
        if hit.processID == sourceProcessID || hit.layer == menuBarLayer { return true }
        return isSystemHelper(hit.bundleIdentifier)
    }

    /// System processes that show UI on behalf of the app in front: the open and save
    /// panel, input methods and their candidate windows, the character viewer,
    /// Quick Look and authentication prompts.
    public static func isSystemHelper(_ bundleIdentifier: String?) -> Bool {
        guard let id = bundleIdentifier else { return false }
        let exact: Set<String> = [
            "com.apple.appkit.xpc.openAndSavePanelService",
            "com.apple.TextInputMenuAgent",
            "com.apple.TextInputSwitcher",
            "com.apple.CharacterPaletteIM",
            "com.apple.PressAndHold",
            "com.apple.SecurityAgent",
            "com.apple.ViewBridgeAuxiliary",
        ]
        if exact.contains(id) { return true }
        return ["com.apple.inputmethod.", "com.apple.TextInputUI", "com.apple.quicklook.",
                "com.apple.QuickLookUIService", "com.apple.AuthenticationServices"].contains { id.hasPrefix($0) }
    }

    // MARK: App switching

    /// Whether another app coming to the front ends the session. The docked app, Dropy
    /// and system helpers do not; anything else does, because its windows would rise
    /// above the docked window while Dropy's outline stayed on top of them.
    public static func activationCloses(processID: Int32, bundleIdentifier: String?, sourceProcessID: Int32,
                                        ownProcessID: Int32) -> Bool {
        processID != sourceProcessID && processID != ownProcessID && !isSystemHelper(bundleIdentifier)
    }

    // MARK: Changes the person makes

    public enum WindowChange: Equatable, Sendable {
        /// Where Dropy put it (within rounding).
        case unchanged
        /// Resized with its top edge still under the notch band: the overlay follows.
        case resizedInPlace
        /// Moved away, or made full screen: the person took it out of the notch.
        case detached
    }

    /// Frames within this many points are the same (AppKit rounds positions).
    public static let tolerance: CGFloat = 2

    /// Classifies a change to the docked window. Frames are global top-left.
    public static func change(expected: CGRect, observed: CGRect, isFullScreen: Bool) -> WindowChange {
        if isFullScreen { return .detached }
        let same = abs(expected.minX - observed.minX) <= tolerance && abs(expected.minY - observed.minY) <= tolerance
            && abs(expected.width - observed.width) <= tolerance && abs(expected.height - observed.height) <= tolerance
        if same { return .unchanged }
        // Resizing from any edge keeps the window overlapping where it was and its top
        // edge where it was (macOS keeps the top below the menu bar); a drag by the
        // title bar moves the top edge.
        if abs(expected.minY - observed.minY) <= tolerance, expected.intersects(observed) { return .resizedInPlace }
        return .detached
    }
}
