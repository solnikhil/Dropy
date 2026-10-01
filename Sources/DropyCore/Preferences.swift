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
    /// The crop region mode shows, per source app. Keyed by bundle identifier because the
    /// choice is about an app's layout (its sidebar, its video area), not about one window
    /// that closes when the app is quit.
    public var selectedRegions: [String: NormalizedRegion]
    /// Apps offered first in the picker, in the order they were pinned. Assigning this
    /// property drops blanks and repeats, so the list can always be numbered.
    public var pinnedBundleIdentifiers: [String] {
        didSet { pinnedBundleIdentifiers = AppPinning.normalized(pinnedBundleIdentifiers) }
    }

    public init(
        trigger: Trigger = .notchHover,
        openBehavior: OpenBehavior = .picker,
        dismissBehavior: DismissBehavior = .manual,
        contentMode: ContentMode = .fit,
        sizePreset: SizePreset = .medium,
        selectedBundleIdentifier: String? = nil,
        lastUsedBundleIdentifier: String? = nil,
        interactivePreview: Bool = false,
        selectedRegions: [String: NormalizedRegion] = [:],
        pinnedBundleIdentifiers: [String] = []
    ) {
        self.trigger = trigger
        self.openBehavior = openBehavior
        self.dismissBehavior = dismissBehavior
        self.contentMode = contentMode
        self.sizePreset = sizePreset
        self.selectedBundleIdentifier = selectedBundleIdentifier
        self.lastUsedBundleIdentifier = lastUsedBundleIdentifier
        self.interactivePreview = interactivePreview
        self.selectedRegions = selectedRegions
        // A property observer does not run for an initializer's own assignment.
        self.pinnedBundleIdentifiers = AppPinning.normalized(pinnedBundleIdentifiers)
    }

    private enum CodingKeys: String, CodingKey {
        case trigger, openBehavior, dismissBehavior, contentMode, sizePreset
        case selectedBundleIdentifier, lastUsedBundleIdentifier, interactivePreview
        case selectedRegions, pinnedBundleIdentifiers
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
        // A region that no longer satisfies its invariants is dropped, like any other
        // unreadable field: losing one crop must not lose every other setting. Losing it
        // is safe because a missing region only means the whole window is shown.
        if let stored = try? container.decodeIfPresent([String: NormalizedRegion].self, forKey: .selectedRegions) {
            selectedRegions = stored
        } else {
            selectedRegions = defaults.selectedRegions
        }
        pinnedBundleIdentifiers = AppPinning.normalized(
            try container.decodeIfPresent([String].self, forKey: .pinnedBundleIdentifiers) ?? defaults.pinnedBundleIdentifiers)
    }

    // MARK: Per-app choices
    //
    // An app with no bundle identifier (a bare executable) can be previewed but cannot be
    // remembered: there is nothing stable to key the choice by, and keying it by process
    // would silently apply someone else's crop after a PID is reused.

    public func selectedRegion(for bundleIdentifier: String?) -> NormalizedRegion? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return selectedRegions[bundleIdentifier]
    }

    /// Stores a region for an app, or clears it when `region` is nil.
    public mutating func setSelectedRegion(_ region: NormalizedRegion?, for bundleIdentifier: String?) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        selectedRegions[bundleIdentifier] = region
    }

    public func isPinned(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return pinnedBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Pins an app at the end of the list, or unpins it, keeping the other pins' order.
    public mutating func togglePin(_ bundleIdentifier: String?) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        pinnedBundleIdentifiers = AppPinning.toggled(pinnedBundleIdentifiers, bundleIdentifier: bundleIdentifier)
    }
}
