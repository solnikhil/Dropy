import Foundation
import DropyCore

@main struct AnimationLibraryChecks {
    @MainActor static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = AnimationLibrary(folder: folder)
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
        print("Animation library checks passed (documents preserved, generated guide refreshed, creation refuses overwrites)")
    }
}
