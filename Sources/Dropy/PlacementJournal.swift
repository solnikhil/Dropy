import DropyCore
import Foundation

/// Persists pending placements so they can be undone after a crash or quit.
/// The file holds only recovery state: window identity, mode and frames. It has
/// no titles or content, and an entry is dropped as soon as its outcome is final.
@MainActor
final class PlacementJournal {
    private let url: URL
    private(set) var entries: [PlacementEntry]

    init(url: URL = PlacementJournal.defaultURL) {
        self.url = url
        entries = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([PlacementEntry].self, from: $0) } ?? []
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Dropy", isDirectory: true)
            .appendingPathComponent("placement-journal.json")
    }

    /// Records or replaces the entry for this exact window and writes it to disk
    /// before returning, so the file is ahead of any change to the window.
    func upsert(_ entry: PlacementEntry) {
        entries.removeAll { $0.identity == entry.identity }
        entries.append(entry)
        save()
    }

    func remove(_ identity: WindowIdentity) {
        entries.removeAll { $0.identity == identity }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if entries.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            }
        } catch {
            NSLog("Dropy placement journal write failed: %@", String(describing: error))
        }
    }

    /// Restores every pending entry, e.g. at launch after a crash or on quit. Entries
    /// that cannot be decided yet (no Accessibility) stay for a later attempt.
    func restoreAll() {
        for entry in entries {
            let decision = WindowPlacer.restore(entry, journal: self)
            NSLog("Dropy placement recovery: mode=%@ outcome=%@", entry.mode.rawValue,
                  decision.map(Self.name) ?? "pending(accessibilityUnavailable)")
        }
    }

    static func name(_ decision: RestoreDecision) -> String {
        switch decision {
        case .restore: "restored"
        case .restoreOnFallbackDisplay: "restoredOnFallbackDisplay"
        case .keepUserChange: "keptUserChange"
        case .sourceGone: "sourceGone"
        }
    }
}
