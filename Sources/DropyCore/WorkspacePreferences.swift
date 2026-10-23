import Foundation

/// Favorites are app identities, never window IDs. Only the active favorite is
/// kept warm; changing favorites restores the previous window through the journal.
public struct FavoriteApp: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bundleIdentifier }
    public let bundleIdentifier: String
    public var sizePreset: SizePreset?
    public var position: OverlayPosition?

    public init(bundleIdentifier: String, sizePreset: SizePreset? = nil, position: OverlayPosition? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.sizePreset = sizePreset
        self.position = position
    }
}

/// Remember exact process incarnations, not titles. After a relaunch or a closed
/// document the user chooses again, even if another window has the same title.
/// These records contain no document names, paths or captured content.
public struct RememberedWindow: Codable, Equatable, Sendable {
    public let identity: WindowIdentity
    public let usedAt: Date

    public init(identity: WindowIdentity, usedAt: Date = Date()) {
        self.identity = identity
        self.usedAt = usedAt
    }
}

public enum WindowSelection: Equatable, Sendable {
    case selected(WindowIdentity)
    case chooseWindow
    case noWindows

    public static func resolve(bundleIdentifier: String, remembered: WindowIdentity?,
                               candidates: [WindowIdentity]) -> WindowSelection {
        let matches = candidates.filter { $0.bundleIdentifier == bundleIdentifier }
        guard !matches.isEmpty else { return .noWindows }
        if let remembered {
            return matches.contains(remembered) ? .selected(remembered) : .chooseWindow
        }
        if matches.count == 1 { return .selected(matches[0]) }
        return .chooseWindow
    }
}

extension DropyPreferences {
    /// Legacy single-pin storage remains the default-opening choice. The collection
    /// also includes it for older callers, without duplicating a favorite.
    public var favoriteApps: [FavoriteApp] {
        var result: [FavoriteApp] = []
        for favorite in favorites where !favorite.bundleIdentifier.isEmpty {
            if !result.contains(where: { $0.id == favorite.id }) { result.append(favorite) }
        }
        if let pinnedBundleIdentifier, !result.contains(where: { $0.id == pinnedBundleIdentifier }) {
            result.insert(FavoriteApp(bundleIdentifier: pinnedBundleIdentifier), at: 0)
        }
        return result
    }

    public mutating func addFavorite(_ bundleIdentifier: String) {
        favorites = favoriteApps
        if !favorites.contains(where: { $0.id == bundleIdentifier }) {
            favorites.append(FavoriteApp(bundleIdentifier: bundleIdentifier))
        }
        if pinnedBundleIdentifier == nil { pinnedBundleIdentifier = bundleIdentifier }
    }

    public mutating func removeFavorite(_ bundleIdentifier: String) {
        favorites = favoriteApps.filter { $0.id != bundleIdentifier }
        if pinnedBundleIdentifier == bundleIdentifier { pinnedBundleIdentifier = nil }
    }

    public mutating func rememberWindow(_ identity: WindowIdentity, at date: Date = Date()) {
        guard let bundleID = identity.bundleIdentifier else { return }
        rememberedWindows.removeAll { $0.identity.bundleIdentifier == bundleID }
        rememberedWindows.insert(RememberedWindow(identity: identity, usedAt: date), at: 0)
        rememberedWindows = Array(rememberedWindows.prefix(30))
        lastUsedBundleIdentifier = bundleID
    }

    public func rememberedWindow(for bundleID: String) -> WindowIdentity? {
        rememberedWindows.first { $0.identity.bundleIdentifier == bundleID }?.identity
    }

    public func presentation(for bundleID: String?) -> DropyPreferences {
        var result = self
        if let favorite = favoriteApps.first(where: { $0.id == bundleID }) {
            if let size = favorite.sizePreset { result.sizePreset = size }
            if let position = favorite.position { result.position = position }
        }
        return result
    }
}

/// Search and ordering share one policy between rendering and keyboard selection.
public struct WindowSearchItem: Equatable, Sendable {
    public let identity: WindowIdentity
    public let applicationName: String
    public let title: String

    public init(identity: WindowIdentity, applicationName: String, title: String) {
        self.identity = identity
        self.applicationName = applicationName
        self.title = title
    }
}

public enum WorkspaceSearch {
    public static func results(_ items: [WindowSearchItem], query: String,
                               favorites: [String], recents: [WindowIdentity]) -> [WindowIdentity] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return items.enumerated().filter { _, item in
            words.allSatisfy { (item.applicationName + " " + item.title).localizedStandardContains($0) }
        }.sorted { lhs, rhs in
            func rank(_ item: WindowSearchItem) -> (Int, Int) {
                (item.identity.bundleIdentifier.flatMap { favorites.firstIndex(of: $0) } ?? Int.max,
                 recents.firstIndex(of: item.identity) ?? Int.max)
            }
            let a = rank(lhs.element), b = rank(rhs.element)
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            return lhs.offset < rhs.offset
        }.map { $0.element.identity }
    }
}
