import Foundation
import DropyCore

@main
struct JournalChecks {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.json")
        let state = WindowPlacementState(frame: CGRect(x: 10, y: 20, width: 300, height: 200), isMinimized: false, isAppHidden: false)
        let entry = PlacementEntry(identity: WindowIdentity(processID: 7, processLaunchDate: Date(timeIntervalSince1970: 1), windowID: 99, bundleIdentifier: "test"), mode: .offscreen, original: state, applied: state, createdAt: Date(timeIntervalSince1970: 2), applicationConfirmed: false)
        let journal = PlacementJournal(url: url)
        precondition(journal.loadError == nil && journal.entries.isEmpty)
        try journal.upsert(entry)
        precondition(PlacementJournal(url: url).entries == [entry])
        try journal.remove(entry.identity)
        precondition(!FileManager.default.fileExists(atPath: url.path))

        let corrupt = Data("unreadable recovery records".utf8)
        try corrupt.write(to: url)
        let damaged = PlacementJournal(url: url)
        precondition(damaged.loadError != nil)
        do { try damaged.upsert(entry); fatalError("must reject corrupted journal") } catch { }
        let preserved = try Data(contentsOf: url)
        precondition(preserved == corrupt)
        precondition(damaged.entries.isEmpty)

        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let blocked = PlacementJournal(url: blocker.appendingPathComponent("journal.json"))
        do { try blocked.upsert(entry); fatalError("must reject persistence failure") } catch { }
        precondition(blocked.entries.isEmpty)

        // Recovery for a window whose exact process is gone (PID 7 with a 1970 launch
        // date never matches). With Accessibility, that is final and the record goes.
        // Without it the window cannot be checked, so the record must stay and retry.
        let recoveryURL = root.appendingPathComponent("recovery.json")
        let recoveryJournal = PlacementJournal(url: recoveryURL)
        try recoveryJournal.upsert(PlacementEntry(identity: entry.identity, mode: .parked, original: state,
                                                  applied: state, createdAt: entry.createdAt, applicationConfirmed: true))
        let recovery = PlacementRecovery(journal: recoveryJournal)
        // A new placement added after recovery was created remains active. Retrying
        // the older orphan must not consume or restore this new record.
        let activeIdentity = WindowIdentity(processID: 8, processLaunchDate: Date(timeIntervalSince1970: 1),
                                            windowID: 100, bundleIdentifier: "test.active")
        let activeEntry = PlacementEntry(identity: activeIdentity, mode: .parked, original: state,
                                         applied: state, createdAt: entry.createdAt, applicationConfirmed: true)
        try recoveryJournal.upsert(activeEntry)
        var settled: [WindowIdentity] = []
        recovery.onSettled = { settled.append($0) }
        let results = recovery.run(resetBackoff: true)
        precondition(results.count == 1)
        if WindowPlacer.isTrusted {
            precondition(results[0].outcome == .decided(.sourceGone), "\(results[0].outcome)")
            precondition(recoveryJournal.entries == [activeEntry] && settled == [entry.identity] && recovery.deferred.isEmpty)
            precondition(PlacementJournal(url: recoveryURL).entries == [activeEntry])
        } else {
            precondition(results[0].outcome == .deferred(.accessibilityNotTrusted), "\(results[0].outcome)")
            precondition(recoveryJournal.entries.count == 2 && settled.isEmpty && recovery.deferred.count == 1)
            precondition(PlacementJournal(url: recoveryURL).entries.count == 2, "records must survive on disk")
        }
        recovery.requestRecovery(for: activeIdentity)
        let explicitlyRequested = recovery.run()
        precondition(explicitlyRequested.contains { $0.entry.identity == activeIdentity },
                     "a requested active placement must become eligible")
        recovery.stop()
        print("Placement journal checks passed (recovery with Accessibility \(WindowPlacer.isTrusted ? "trusted" : "not trusted"))")
    }
}
