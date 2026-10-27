import Foundation
import Darwin
import DropyCore

private final class WatcherLifetimeProbe: Sendable {}

@main struct AnimationLibraryChecks {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = AnimationLibrary(folder: folder)
        try verifyBoundedReads(in: folder)
        try verifyPreservedTimestampEdits(in: folder)
        let personalDocuments: [(String, Data)] = [
            ("README.md", Data(repeating: 120, count: AnimationFile.maximumSize + 1)),
            ("AGENTS.md", Data([0xff, 0xfe, 0x41, 0x00])),
            ("CLAUDE.md", Data("My animation instructions\n".utf8)),
        ]
        for (name, data) in personalDocuments {
            try data.write(to: folder.appendingPathComponent(name))
        }
        library.prepareFolder()
        for (name, data) in personalDocuments {
            let saved = try Data(contentsOf: folder.appendingPathComponent(name))
            precondition(saved == data,
                         "Preparing animations must preserve the person's \(name), regardless of size or encoding")
        }
        let readme = folder.appendingPathComponent("README.md")
        try Data((AnimationGuide.generatedMarker + "old generated guide").utf8).write(to: readme)
        library.prepareFolder()
        let refreshed = try String(contentsOf: readme, encoding: .utf8)
        precondition(refreshed.hasPrefix(AnimationGuide.generatedMarker) && !refreshed.contains("old generated guide"))
        precondition(FileManager.default.fileExists(atPath: library.examplesFolder.appendingPathComponent("pop.json").path))

        let original = MotionStyle.balanced.animation
        let existing = try library.save(original, as: "My-Animation")
        let originalData = try Data(contentsOf: existing)
        // Even a stale catalog or a case-insensitive filesystem must not allow a
        // create operation to overwrite a file that is already on disk.
        for id in ["My-Animation", "my-animation"] {
            let target = folder.appendingPathComponent("\(id).json")
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                try library.save(MotionStyle.rapid.animation, as: id)
                preconditionFailure("Creating an animation must refuse an existing target")
            } catch {
                let saved = try Data(contentsOf: existing)
                precondition(saved == originalData, "A refused creation must leave the existing animation intact")
            }
        }
        let copyID = library.freeID(for: "My Animation")
        let copy = try library.save(MotionStyle.rapid.animation, as: copyID)
        precondition(copy != existing && library.entry(copyID)?.animation != nil)
        try await verifyWatcherLifetime(in: folder)
        print("Animation library checks passed (documents preserved, generated guide refreshed, creation refuses overwrites)")
    }

    @MainActor private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for a folder-watcher lifecycle event")
    }

    @MainActor private static func verifyBoundedReads(in folder: URL) throws {
        let file = folder.appendingPathComponent("bounded-read.json")
        let link = folder.appendingPathComponent("bounded-link.json")
        let fifo = folder.appendingPathComponent("pipe.json")
        defer {
            for url in [file, link, fifo] { try? FileManager.default.removeItem(at: url) }
        }
        let exact = Data(repeating: 120, count: AnimationFile.maximumSize)
        try exact.write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        precondition(AnimationLibrary.data(at: file) == exact)
        precondition(AnimationLibrary.data(at: link) == exact)
        try Data(repeating: 120, count: AnimationFile.maximumSize + 1).write(to: file)
        precondition(AnimationLibrary.data(at: file) == nil)
        precondition(AnimationLibrary.data(at: link) == nil, "Symlinks must not bypass the read limit")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        precondition(AnimationLibrary.data(at: fifo) == nil, "A named pipe must be refused without waiting for a writer")
        precondition(AnimationLibrary.data(at: folder) == nil)
    }

    @MainActor private static func verifyPreservedTimestampEdits(in folder: URL) throws {
        let file = folder.appendingPathComponent("timestamp-edit.json")
        defer { try? FileManager.default.removeItem(at: file) }
        let date = Date(timeIntervalSince1970: 1_000)
        try Data(#"{"dropyAnimation":1,"name":"Before"}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let library = AnimationLibrary(folder: folder)
        library.scan(notify: false)
        precondition(library.entry("timestamp-edit")?.name == "Before")
        var changes = 0
        library.onChange = { changes += 1 }
        library.scan()
        precondition(changes == 0)
        try Data(#"{"dropyAnimation":1,"name":"After!"}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        library.scan()
        precondition(library.entry("timestamp-edit")?.name == "After!", "Preserved timestamps must not hide content changes")
        precondition(changes == 1)
        library.scan()
        precondition(changes == 1, "An unchanged snapshot must not trigger another update")
    }

    @MainActor private static func verifyWatcherLifetime(in folder: URL) async throws {
        var events = 0
        var probe: WatcherLifetimeProbe? = WatcherLifetimeProbe()
        weak var callbackContext = probe
        var watcher = AnimationFolderWatcher(folder: folder) { [probe = probe!] in
            withExtendedLifetime(probe) {}
            events += 1
        }
        precondition(watcher != nil)
        probe = nil
        precondition(callbackContext != nil)
        try Data("event".utf8).write(to: folder.appendingPathComponent("watcher-event.txt"))
        await waitUntil { events > 0 }
        watcher = nil
        await waitUntil { callbackContext == nil }
        let stoppedAt = events
        try Data("after teardown".utf8).write(to: folder.appendingPathComponent("after-teardown.txt"))
        try await Task.sleep(for: .milliseconds(300))
        precondition(events == stoppedAt, "A released watcher must not keep delivering callbacks")

        var watchingLibrary: AnimationLibrary? = AnimationLibrary(folder: folder)
        weak var releasedLibrary = watchingLibrary
        watchingLibrary?.start()
        watchingLibrary?.start()
        precondition(watchingLibrary?.isWatching == true)
        let data = AnimationFile.data(for: MotionStyle.balanced.animation)
        try data.write(to: folder.appendingPathComponent("watcher-added.json"))
        await waitUntil { watchingLibrary?.entry("watcher-added") != nil }
        watchingLibrary?.stop()
        watchingLibrary?.stop()
        precondition(watchingLibrary?.isWatching == false)
        try data.write(to: folder.appendingPathComponent("while-stopped.json"))
        try await Task.sleep(for: .milliseconds(300))
        precondition(watchingLibrary?.entry("while-stopped") == nil)
        watchingLibrary?.start()
        precondition(watchingLibrary?.entry("while-stopped") != nil)
        watchingLibrary = nil
        precondition(releasedLibrary == nil, "A live watcher must not retain its library")
        print("Folder watcher checks passed (real events, context release, stop/restart, owner destruction)")
    }
}
