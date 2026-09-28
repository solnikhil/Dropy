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
        print("Placement journal checks passed")
    }
}
