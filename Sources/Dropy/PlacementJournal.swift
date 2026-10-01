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
    /// Valid records may be recovered after a durable copy preserves every damaged
    /// record. New placements remain blocked until the quarantine is resolved.
    private(set) var canRecover = true
    private var quarantineMarker: URL { url.appendingPathExtension("recovery-blocked") }
    private(set) var quarantineURL: URL?

    init(url: URL = PlacementJournal.defaultURL) {
        self.url = url
        entries = []
        do {
            let data = try Data(contentsOf: url)
            do {
                entries = try JSONDecoder().decode([PlacementEntry].self, from: data)
                guard entries.allSatisfy(Self.valid), Set(entries.map(\.identity)).count == entries.count else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } catch {
                // Decode independently so one damaged record cannot strand every
                // other hidden window. Ambiguous duplicate identities are excluded.
                guard let objects = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw error }
                let candidates = objects.compactMap { object -> PlacementEntry? in
                    guard let encoded = try? JSONSerialization.data(withJSONObject: object),
                          let entry = try? JSONDecoder().decode(PlacementEntry.self, from: encoded),
                          Self.valid(entry) else { return nil }
                    return entry
                }
                let counts = Dictionary(grouping: candidates, by: \.identity).mapValues(\.count)
                let safe = candidates.filter { counts[$0.identity] == 1 }
                guard !safe.isEmpty else { throw error }
                let backup = url.appendingPathExtension("corrupt-" + UUID().uuidString)
                try data.write(to: backup, options: .atomic)
                try Data(backup.path.utf8).write(to: quarantineMarker, options: .atomic)
                quarantineURL = backup
                entries = safe
                loadError = error
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // No pending placement, but a quarantine marker can still block new moves.
        } catch {
            entries = []
            loadError = error
            canRecover = false
            NSLog("Dropy placement journal unreadable; preserving file and blocking new placements: %@", String(describing: error))
        }
        if FileManager.default.fileExists(atPath: quarantineMarker.path) {
            do {
                let marker = try String(contentsOf: quarantineMarker, encoding: .utf8)
                guard !marker.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                quarantineURL = URL(fileURLWithPath: marker)
                loadError = loadError ?? CocoaError(.fileReadCorruptFile)
            } catch {
                loadError = error
                canRecover = false
            }
        }
    }

    private static func valid(_ entry: PlacementEntry) -> Bool {
        func frameIsValid(_ frame: CGRect) -> Bool {
            [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
                && frame.width > 0 && frame.height > 0
        }
        if let handOff = entry.handOff {
            guard frameIsValid(handOff.restoredTo.frame), handOff.startedAt.timeIntervalSince1970.isFinite else { return false }
        }
        return entry.identity.processID > 0 && entry.identity.windowID > 0
            && (entry.identity.bundleIdentifier.map { !$0.isEmpty } ?? true)
            && entry.identity.processLaunchDate.timeIntervalSince1970.isFinite
            && entry.createdAt.timeIntervalSince1970.isFinite
            && frameIsValid(entry.original.frame) && frameIsValid(entry.applied.frame)
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
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

    /// Recovery may mark an existing, validated record before touching its window.
    /// It cannot introduce or alter a target, original state or restore destination.
    func markRestoreInProgress(_ entry: PlacementEntry) throws {
        guard let index = entries.firstIndex(of: entry) else { throw CocoaError(.fileWriteUnknown) }
        var next = entries
        next[index].applicationConfirmed = false
        try save(next, recovering: true)
        entries = next
    }

    func remove(_ identity: WindowIdentity) throws {
        let next = entries.filter { $0.identity != identity }
        try save(next, recovering: true)
        entries = next
    }

    private func save(_ next: [PlacementEntry], recovering: Bool = false) throws {
        if let loadError {
            guard recovering, canRecover, let quarantineURL,
                  FileManager.default.fileExists(atPath: quarantineURL.path),
                  FileManager.default.fileExists(atPath: quarantineMarker.path) else { throw loadError }
        }
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
    func restoreAll(identities: Set<WindowIdentity>? = nil) -> [(entry: PlacementEntry, outcome: RestoreOutcome)] {
        entries.filter { entry in identities.map { $0.contains(entry.identity) } ?? true }.map { entry in
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
