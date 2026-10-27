import Foundation
import DropyCore

@main struct AnimationStudioChecks {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try verifyOriginalFileURL(in: folder)
        try verifyCrowdedKeyframes(in: folder)
        try await verifyExternalEditsSurviveAutosave(in: folder)
        print("Animation Studio checks passed (original file path preserved; no windows shown)")
    }

    @MainActor private static func fixture(in root: URL, filename: String = "studio.json",
                                           animation: DropyAnimation = MotionStyle.balanced.animation) throws
        -> (library: AnimationLibrary, model: AnimationStudioModel, file: URL) {
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(filename)
        try AnimationFile.data(for: animation).write(to: file)
        let library = AnimationLibrary(folder: folder)
        library.scan(notify: false)
        let id = file.deletingPathExtension().lastPathComponent
        let model = AnimationStudioModel(library: library, fileID: id, animation: animation)
        return (library, model, file)
    }

    @MainActor private static func verifyOriginalFileURL(in folder: URL) throws {
        let (library, model, file) = try fixture(in: folder, filename: "Uppercase.JSON")
        precondition(model.url.lastPathComponent == "Uppercase.JSON")
        precondition(library.quotedPath(for: "Uppercase") == AnimationText.shellQuoted(file.path))
        model.rename("Edited uppercase file")
        model.saveNow()
        precondition(AnimationLibrary.read(file).animation?.name == "Edited uppercase file")
    }

    @MainActor private static func verifyCrowdedKeyframes(in folder: URL) throws {
        for spacing in [0.001, 0.0002] {
            var animation = MotionStyle.balanced.animation
            animation.open.height = .keyframes([
                MotionKeyframe(time: 0, value: 0), MotionKeyframe(time: spacing, value: 0.2),
                MotionKeyframe(time: 2 * spacing, value: 1),
            ])
            let (_, model, file) = try fixture(in: folder, animation: animation)
            model.moveKey(1, time: spacing, value: 0.4)
            precondition(model.keys?[1].time == spacing)
            precondition(model.keys?[1].value == 0.4)
            model.saveNow()
            let result = AnimationLibrary.read(file)
            precondition(result.errors.isEmpty)
            if case .keyframes(let keys) = result.animation?.open.height {
                precondition(zip(keys, keys.dropFirst()).allSatisfy { $0.time < $1.time })
                precondition(keys[1].time == spacing, "Dragging must not reorder closely spaced imported keys")
            } else { preconditionFailure("Expected a saved keyframe curve") }
        }
    }

    @MainActor private static func settleUpdates() async throws {
        try await Task.sleep(for: .milliseconds(30))
    }

    @MainActor private static func verifyExternalEditsSurviveAutosave(in folder: URL) async throws {
        for gesture in [false, true] {
            let (library, model, file) = try fixture(in: folder)
            if gesture { model.beginGesture() }
            model.rename("Pending Studio edit")
            let external = Data("{ unfinished external edit".utf8)
            try external.write(to: file)
            library.scan()
            try await settleUpdates()
            if gesture { model.endGesture() }
            model.saveNow()
            try await Task.sleep(for: .milliseconds(400))
            let preserved = try Data(contentsOf: file)
            precondition(preserved == external, "A pending autosave or close must not replace an external invalid edit")
            precondition(!model.errors.isEmpty)
        }

        // Closing a model after an outside formatting/comment change must not
        // rewrite the document just because its serialization differs.
        let (library, model, file) = try fixture(in: folder)
        let external = Data("// keep my comment\n".utf8) + AnimationFile.data(for: model.animation)
        try external.write(to: file)
        library.scan()
        try await settleUpdates()
        model.saveNow()
        let preserved = try Data(contentsOf: file)
        precondition(preserved == external)

        // A manual save must notice an external edit even without a delivered
        // catalog update, and that valid outside edit must remain undoable.
        model.rename("Unsaved local work")
        var outside = model.animation
        outside.name = "Outside change"
        let outsideData = AnimationFile.data(for: outside)
        try outsideData.write(to: file)
        model.saveNow()
        precondition(model.animation.name == "Outside change" && model.canUndo)
        let savedOutside = try Data(contentsOf: file)
        precondition(savedOutside == outsideData)
        try await settleUpdates()
        model.undo()
        precondition(model.animation.name == "Unsaved local work")
        model.saveNow()
    }
}
