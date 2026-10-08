import AppKit
import CoreServices
import DropyCore

/// The person's animations: the `.json` files in
/// ~/Library/Application Support/Dropy/Animations. The folder is watched, so a file
/// saved by the Animation Studio, a text editor or an AI agent is picked up at once.
/// Dropy also keeps a guide there (README.md, with AGENTS.md and CLAUDE.md pointing to
/// it for coding agents) and the built-in styles and examples under Examples/.
@MainActor
final class AnimationLibrary: ObservableObject {
    struct Entry: Identifiable, Equatable {
        /// The file name without ".json"; what the preference and the commands use.
        let id: String
        let url: URL
        var result: AnimationReadResult
        var modified: Date

        var animation: DropyAnimation? { result.animation }
        var name: String { result.animation?.name ?? id }
    }

    /// Which animation the overlay uses, and why when it is not the one chosen.
    struct Choice: Equatable {
        var animation: DropyAnimation
        /// Set when the chosen file could not be used.
        var problem: String?
    }

    /// `DROPY_ANIMATIONS_FOLDER` points the app and its commands elsewhere (checks use a
    /// throwaway folder, never the person's).
    static let defaultFolder: URL = ProcessInfo.processInfo.environment["DROPY_ANIMATIONS_FOLDER"]
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dropy", isDirectory: true)
            .appendingPathComponent("Animations", isDirectory: true)

    let folder: URL
    var examplesFolder: URL { folder.appendingPathComponent("Examples", isDirectory: true) }
    @Published private(set) var entries: [Entry] = []
    /// Called after the files change (not for the initial scan).
    var onChange: (() -> Void)?
    private var stream: FSEventStreamRef?
    private var pendingScan = false

    init(folder: URL = AnimationLibrary.defaultFolder) {
        self.folder = folder
    }

    /// How to run Dropy's animation commands from a terminal.
    static var command: String {
        "\"\(Bundle.main.executablePath ?? "/Applications/Dropy.app/Contents/MacOS/Dropy")\" animation"
    }

    // MARK: Starting

    /// Creates the folder and its guide, reads the animations and starts watching.
    func start() {
        prepareFolder()
        scan(notify: false)
        watch()
    }

    /// The folder, the guide for people and agents, and the examples, written only when
    /// they differ. A README, AGENTS.md or CLAUDE.md the person wrote themselves (one
    /// without Dropy's marker) is left alone.
    func prepareFolder() {
        let manager = FileManager.default
        try? manager.createDirectory(at: examplesFolder, withIntermediateDirectories: true)
        let path = (folder.path as NSString).abbreviatingWithTildeInPath
        writeIfChanged(AnimationGuide.readme(folder: path, command: Self.command), to: folder.appendingPathComponent("README.md"))
        for name in ["AGENTS.md", "CLAUDE.md"] {
            writeIfChanged(AnimationGuide.agentPointer, to: folder.appendingPathComponent(name))
        }
        for (id, animation) in Self.examples {
            let url = examplesFolder.appendingPathComponent("\(id).json")
            let data = AnimationFile.data(for: animation)
            if (try? Data(contentsOf: url)) != data { try? data.write(to: url, options: .atomic) }
        }
    }

    private func writeIfChanged(_ text: String, to url: URL) {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing != text else { return }
        if let existing, !existing.hasPrefix(AnimationGuide.generatedMarker) { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    /// The built-in styles and the gallery, as written to Examples/.
    static var examples: [(id: String, animation: DropyAnimation)] {
        MotionStyle.allCases.map { ($0.rawValue, $0.animation) } + DropyAnimation.gallery
    }

    // MARK: Reading

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    /// Reads every animation file in the folder (not the examples).
    func scan(notify: Bool = true) {
        let manager = FileManager.default
        let urls = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])) ?? []
        var next: [Entry] = []
        for url in urls where url.pathExtension.lowercased() == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let old = entry(id), old.modified == modified, old.url == url {
                next.append(old)
                continue
            }
            let result: AnimationReadResult
            if let data = try? Data(contentsOf: url) {
                result = AnimationFile.read(data, fallbackName: Self.title(for: id))
            } else {
                result = AnimationReadResult(animation: nil, issues: [AnimationIssue(.error, "", "The file could not be read.")])
            }
            next.append(Entry(id: id, url: url, result: result, modified: modified))
        }
        next.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard next != entries else { return }
        entries = next
        if notify { onChange?() }
    }

    /// Which animation to use for `preferences`: the chosen file when it can be used,
    /// otherwise the chosen built-in style, with the reason.
    func choice(for preferences: DropyPreferences) -> Choice {
        let style = preferences.motionStyle.animation
        guard let id = preferences.customAnimation else { return Choice(animation: style) }
        guard let entry = entry(id) else {
            return Choice(animation: style, problem: "“\(id).json” is no longer in the animations folder. Using \(style.name).")
        }
        guard let animation = entry.animation else {
            let first = entry.result.errors.first.map { $0.path.isEmpty ? $0.message : "\($0.path): \($0.message)" } ?? ""
            return Choice(animation: style, problem: "“\(entry.name)” has a problem, so \(style.name) is used until it is fixed. \(first)")
        }
        return Choice(animation: animation)
    }

    // MARK: Writing

    /// Saves `animation` as `<id>.json` and reads the folder again.
    @discardableResult
    func save(_ animation: DropyAnimation, as id: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(id).json")
        try AnimationFile.data(for: animation).write(to: url, options: .atomic)
        scan()
        return url
    }

    /// A file name for `name` that is not taken yet: "Springy Drop" → "springy-drop",
    /// then "springy-drop-2"…
    func freeID(for name: String) -> String {
        let base = Self.slug(name)
        var id = base
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(id).json").path) {
            id = "\(base)-\(number)"
            number += 1
        }
        return id
    }

    /// Moves the file to the Trash, so a mistake can be undone in Finder.
    func delete(_ id: String) {
        guard let entry = entry(id) else { return }
        try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        scan()
    }

    static func slug(_ name: String) -> String {
        let lowered = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var slug = ""
        for character in lowered {
            if character.isLetter || character.isNumber { slug.append(character) } else if !slug.hasSuffix("-") { slug.append("-") }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "animation" : String(slug.prefix(60))
    }

    /// "springy-drop" → "Springy Drop", for files without a name.
    static func title(for id: String) -> String {
        id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: Watching

    private func watch() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let library = Unmanaged<AnimationLibrary>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { library.scheduleScan() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
            NSLog("Dropy animations: cannot watch %@", folder.path)
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Editors often save in several steps; read once they are done.
    private func scheduleScan() {
        guard !pendingScan else { return }
        pendingScan = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.pendingScan = false
            self?.scan()
        }
    }
}
