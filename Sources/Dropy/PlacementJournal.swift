import DropyCore
import Foundation

/// Persists pending placements so they can be undone after a crash or quit.
/// The file holds only recovery state: window identity, mode and frames. It has
/// no titles or content, and an entry is dropped as soon as its outcome is final.
@MainActor
final class PlacementJournal {
    private let url: URL
    private(set) var entries: [PlacementEntry]
    private(set) var loadError: Error?

    init(url: URL = PlacementJournal.defaultURL) {
        self.url = url
        entries = []
        do {
            let data = try Data(contentsOf: url)
            entries = try JSONDecoder().decode([PlacementEntry].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // No pending placement.
        } catch {
            loadError = error
            NSLog("Dropy placement journal unreadable; preserving file and blocking new placements: %@", String(describing: error))
        }
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Dropy", isDirectory: true)
            .appendingPathComponent("placement-journal.json")
    }

    /// Records or replaces the entry for this exact window and writes it to disk
    /// before returning, so the file is ahead of any change to the window.
    func upsert(_ entry: PlacementEntry) throws {
        var next = entries.filter { $0.identity != entry.identity }
        next.append(entry)
        try save(next)
        entries = next
    }

    func remove(_ identity: WindowIdentity) throws {
        let next = entries.filter { $0.identity != identity }
        try save(next)
        entries = next
    }

    private func save(_ next: [PlacementEntry]) throws {
        if let loadError { throw loadError }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Persist even an empty journal atomically. A failed write leaves the
        // previous records intact, and never authorizes a source mutation.
        if next.isEmpty {
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        } else {
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
        }
    }

    /// Tries to restore every pending entry once, e.g. at launch after a crash or on
    /// quit. Entries that cannot be decided or reached yet stay, with the reason.
    @discardableResult
    func restoreAll() -> [(entry: PlacementEntry, outcome: RestoreOutcome)] {
        entries.map { entry in
            let outcome = WindowPlacer.restore(entry, journal: self)
            NSLog("Dropy placement recovery: mode=%@ window=%u outcome=%@", entry.mode.rawValue,
                  entry.identity.windowID, Self.name(outcome))
            return (entry, outcome)
        }
    }

    static func name(_ outcome: RestoreOutcome) -> String {
        switch outcome {
        case .decided(let decision): name(decision)
        case .deferred(let reason): "deferred(\(reason))"
        }
    }

    static func name(_ decision: RestoreDecision) -> String {
        switch decision {
        case .restore: "restored"
        case .restoreOnFallbackDisplay: "restoredOnFallbackDisplay"
        case .keepUserChange: "keptUserChange"
        case .sourceGone: "sourceGone"
        case .pending: "pending(unconfirmedPlacement)"
        }
    }
}
