import Foundation
import CoreGraphics

public enum OpenBehavior: String, Codable, CaseIterable, Sendable {
    case direct
    case lastUsed
    case picker
}

public enum Trigger: String, Codable, CaseIterable, Sendable {
    case notchHover
    case notchClick
    case shortcut

    /// Opening from the notch is paused while the shortcut flow is worked on: every
    /// trigger behaves as `shortcut`. The saved choice is kept, so turning this off
    /// brings back whatever was picked.
    public static let notchPaused = true

    /// The trigger Dropy acts on, given the saved one.
    public var effective: Trigger { Self.notchPaused ? .shortcut : self }
}

public enum DismissBehavior: String, Codable, CaseIterable, Sendable {
    case pointerLeave
    case clickOutside
    case manual
}

public enum ContentMode: String, Codable, CaseIterable, Sendable {
    case fit
    case fill
    case nativeScale
    case selectedRegion
}

public enum SizePreset: String, Codable, CaseIterable, Sendable {
    case compact
    case medium
    case wide
    /// The chosen window at its own size, scaled down only if it would not fit the screen.
    case nativeSize

    /// The overlay's size while choosing a window, and for a preset the most a
    /// chosen window may take.
    public var dimensions: CGSize {
        switch self {
        case .compact: CGSize(width: 600, height: 360)
        case .medium, .nativeSize: CGSize(width: 900, height: 540)
        case .wide: CGSize(width: 1200, height: 700)
        }
    }

    /// The most a chosen window may take; nil leaves only the screen as the limit.
    public var maximumSize: CGSize? { self == .nativeSize ? nil : dimensions }

    public var title: String { self == .nativeSize ? "Native size" : rawValue.capitalized }
}

/// A system-wide shortcut as Carbon registers it: a virtual key code and a Carbon
/// modifier mask (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000).
public struct KeyShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// As shown to the person, e.g. "⌃⌥D"; recorded with the shortcut.
    public var display: String

    public init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    public static let command: UInt32 = 0x100
    public static let shift: UInt32 = 0x200
    public static let option: UInt32 = 0x800
    public static let control: UInt32 = 0x1000

    /// Option-Space. (Option-Command-D, the first default, is macOS's "Turn Dock
    /// hiding on/off".)
    public static let `default` = KeyShortcut(keyCode: 49, modifiers: option, display: "⌥Space")
    /// The default until 2026-10-04; saved settings still holding it move to `default`.
    public static let previousDefault = KeyShortcut(keyCode: 2, modifiers: control | option, display: "⌃⌥D")

    /// A global shortcut needs Command, Control or Option; Shift alone would take a
    /// character away from typing everywhere.
    public var isAcceptable: Bool { modifiers & (Self.command | Self.control | Self.option) != 0 }

    /// Modifier symbols in the order macOS menus show them.
    public static func symbols(for modifiers: UInt32) -> String {
        (modifiers & control != 0 ? "⌃" : "") + (modifiers & option != 0 ? "⌥" : "")
            + (modifiers & shift != 0 ? "⇧" : "") + (modifiers & command != 0 ? "⌘" : "")
    }

    /// Modifier symbols, then the key, in the order macOS menus show them.
    /// "⌥Space" becomes ["⌥", "Space"].
    public var keycaps: [String] {
        var caps: [String] = []
        if modifiers & Self.control != 0 { caps.append("⌃") }
        if modifiers & Self.option != 0 { caps.append("⌥") }
        if modifiers & Self.shift != 0 { caps.append("⇧") }
        if modifiers & Self.command != 0 { caps.append("⌘") }
        let prefix = Self.symbols(for: modifiers)
        let key = display.hasPrefix(prefix) ? String(display.dropFirst(prefix.count)) : display
        if !key.isEmpty { caps.append(key) }
        return caps
    }
}

public struct DropyPreferences: Codable, Equatable, Sendable {
    public var trigger: Trigger
    public var openBehavior: OpenBehavior
    public var dismissBehavior: DismissBehavior
    public var contentMode: ContentMode
    public var sizePreset: SizePreset
    public var selectedBundleIdentifier: String?
    public var lastUsedBundleIdentifier: String?
    /// Send clicks, scrolling and typing in the preview to the source window, where
    /// verified. Off by default: interaction is a beta that needs Accessibility.
    public var restrictNotchCrossing: Bool
    public var automaticWindowSize: Bool
    public var interactivePreview: Bool
    /// Show a Dock icon and Dropy's own menu bar like an ordinary app. Off leaves only
    /// the menu-bar item (the Settings window still brings the Dock icon while open).
    public var showInDock: Bool
    /// The app shown in the notch: every opening shows its window, launching the app
    /// first when needed. Nil leaves the open behavior to choose.
    public var pinnedBundleIdentifier: String?
    /// Opens and closes the overlay from anywhere.
    public var shortcut: KeyShortcut

    public init(
        trigger: Trigger = .notchHover,
        openBehavior: OpenBehavior = .picker,
        dismissBehavior: DismissBehavior = .pointerLeave,
        contentMode: ContentMode = .fit,
        sizePreset: SizePreset = .compact,
        selectedBundleIdentifier: String? = nil,
        lastUsedBundleIdentifier: String? = nil,
        restrictNotchCrossing: Bool = false,
        automaticWindowSize: Bool = true,
        interactivePreview: Bool = false,
        showInDock: Bool = true,
        pinnedBundleIdentifier: String? = nil,
        shortcut: KeyShortcut = .default
    ) {
        self.trigger = trigger
        self.openBehavior = openBehavior
        self.dismissBehavior = dismissBehavior
        self.contentMode = contentMode
        self.sizePreset = sizePreset
        self.selectedBundleIdentifier = selectedBundleIdentifier
        self.lastUsedBundleIdentifier = lastUsedBundleIdentifier
        self.restrictNotchCrossing = restrictNotchCrossing
        self.automaticWindowSize = automaticWindowSize
        self.interactivePreview = interactivePreview
        self.showInDock = showInDock
        self.pinnedBundleIdentifier = pinnedBundleIdentifier
        self.shortcut = shortcut
    }

    /// The app whose window an opening selects by itself, if any. A pinned app wins
    /// over the open behavior.
    public var openTargetBundleIdentifier: String? {
        if let pinnedBundleIdentifier { return pinnedBundleIdentifier }
        switch openBehavior {
        case .direct: return selectedBundleIdentifier
        case .lastUsed: return lastUsedBundleIdentifier
        case .picker: return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case trigger, openBehavior, dismissBehavior, contentMode, sizePreset
        case selectedBundleIdentifier, lastUsedBundleIdentifier, interactivePreview, showInDock
        case pinnedBundleIdentifier, shortcut, restrictNotchCrossing, automaticWindowSize
    }

    /// Settings saved before a field existed keep every other choice; a new field takes
    /// its default instead of discarding the whole record.
    public init(from decoder: Decoder) throws {
        let defaults = DropyPreferences()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try container.decodeIfPresent(Trigger.self, forKey: .trigger) ?? defaults.trigger
        openBehavior = try container.decodeIfPresent(OpenBehavior.self, forKey: .openBehavior) ?? defaults.openBehavior
        dismissBehavior = try container.decodeIfPresent(DismissBehavior.self, forKey: .dismissBehavior) ?? defaults.dismissBehavior
        contentMode = try container.decodeIfPresent(ContentMode.self, forKey: .contentMode) ?? defaults.contentMode
        // "trueSize" was Native size's name in commit 157d2df.
        let savedSize = try container.decodeIfPresent(String.self, forKey: .sizePreset)
        sizePreset = savedSize.flatMap { SizePreset(rawValue: $0 == "trueSize" ? "nativeSize" : $0) } ?? defaults.sizePreset
        selectedBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .selectedBundleIdentifier)
        lastUsedBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .lastUsedBundleIdentifier)
        restrictNotchCrossing = try container.decodeIfPresent(Bool.self, forKey: .restrictNotchCrossing) ?? defaults.restrictNotchCrossing
        automaticWindowSize = try container.decodeIfPresent(Bool.self, forKey: .automaticWindowSize) ?? defaults.automaticWindowSize
        interactivePreview = try container.decodeIfPresent(Bool.self, forKey: .interactivePreview) ?? defaults.interactivePreview
        showInDock = try container.decodeIfPresent(Bool.self, forKey: .showInDock) ?? defaults.showInDock
        pinnedBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .pinnedBundleIdentifier)
        let savedShortcut = try container.decodeIfPresent(KeyShortcut.self, forKey: .shortcut)
        shortcut = savedShortcut == KeyShortcut.previousDefault ? defaults.shortcut : savedShortcut ?? defaults.shortcut
    }
}
