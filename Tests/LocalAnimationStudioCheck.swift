import Foundation
import DropyCore

@main struct AnimationStudioChecks {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try verifyOriginalFileURL(in: folder)
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
}
