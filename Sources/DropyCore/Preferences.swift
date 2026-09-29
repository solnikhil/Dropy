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

    public var dimensions: CGSize {
        switch self {
        case .compact: CGSize(width: 600, height: 360)
        case .medium: CGSize(width: 900, height: 540)
        case .wide: CGSize(width: 1200, height: 700)
        }
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
    public var interactivePreview: Bool

    public init(
        trigger: Trigger = .notchHover,
        openBehavior: OpenBehavior = .picker,
        dismissBehavior: DismissBehavior = .manual,
        contentMode: ContentMode = .fit,
        sizePreset: SizePreset = .medium,
        selectedBundleIdentifier: String? = nil,
        lastUsedBundleIdentifier: String? = nil,
        interactivePreview: Bool = false
    ) {
        self.trigger = trigger
        self.openBehavior = openBehavior
        self.dismissBehavior = dismissBehavior
        self.contentMode = contentMode
        self.sizePreset = sizePreset
        self.selectedBundleIdentifier = selectedBundleIdentifier
        self.lastUsedBundleIdentifier = lastUsedBundleIdentifier
        self.interactivePreview = interactivePreview
    }

    private enum CodingKeys: String, CodingKey {
        case trigger, openBehavior, dismissBehavior, contentMode, sizePreset
        case selectedBundleIdentifier, lastUsedBundleIdentifier, interactivePreview
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
        sizePreset = try container.decodeIfPresent(SizePreset.self, forKey: .sizePreset) ?? defaults.sizePreset
        selectedBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .selectedBundleIdentifier)
        lastUsedBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .lastUsedBundleIdentifier)
        interactivePreview = try container.decodeIfPresent(Bool.self, forKey: .interactivePreview) ?? defaults.interactivePreview
    }
}
