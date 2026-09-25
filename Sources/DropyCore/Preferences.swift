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

    public init(
        trigger: Trigger = .notchHover,
        openBehavior: OpenBehavior = .picker,
        dismissBehavior: DismissBehavior = .manual,
        contentMode: ContentMode = .fit,
        sizePreset: SizePreset = .medium,
        selectedBundleIdentifier: String? = nil,
        lastUsedBundleIdentifier: String? = nil
    ) {
        self.trigger = trigger
        self.openBehavior = openBehavior
        self.dismissBehavior = dismissBehavior
        self.contentMode = contentMode
        self.sizePreset = sizePreset
        self.selectedBundleIdentifier = selectedBundleIdentifier
        self.lastUsedBundleIdentifier = lastUsedBundleIdentifier
    }
}
