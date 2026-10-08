import AppKit
import Combine
import SwiftUI
import DropyCore

/// One animation file open in the Animation Studio: the edits, their undo history,
/// saving, checking and playback. Every edit is saved to the file shortly after it is
/// made, and a change to the file from elsewhere (an AI agent, a text editor) is
/// picked up while the Studio is open.
@MainActor
final class AnimationStudioModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case open, resize, close, content
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var part: DropyAnimation.Part? { DropyAnimation.Part(rawValue: rawValue) }
    }

    enum Channel: String, CaseIterable, Identifiable {
        case width, height
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var detail: String {
            switch self {
            case .width: "The width, and the curved ears where the outline meets the top of the screen."
            case .height: "The height, and the rounded lower corners."
            }
        }
    }

    enum Tool: String { case select, draw }

    let library: AnimationLibrary
    let fileID: String
    @Published private(set) var animation: DropyAnimation
    @Published var tab: Tab = .open { didSet { if tab != oldValue { selectedKey = nil } } }
    @Published var channel: Channel = .height { didSet { if channel != oldValue { selectedKey = nil } } }
    @Published var selectedKey: Int?
    @Published var tool: Tool = .select
    @Published var slowdown: Double = 1
    @Published var loop = false { didSet { if loop != oldValue { play() } } }
    /// Bumped to make the stage play `playParts`.
    @Published private(set) var playRequest = 0
    @Published private(set) var playParts = DropyAnimation.Part.allCases
    /// The motion playing on the stage, for the timeline's playhead.
    @Published private(set) var playing: (part: DropyAnimation.Part, start: CFTimeInterval, slowdown: Double)?
    /// What the file format says about the animation as it stands.
    @Published private(set) var issues: [AnimationIssue] = []
    /// Set when the file was deleted or renamed while open.
    @Published private(set) var fileMissing = false
    @Published private(set) var shareCodeCopied = false

    var playOnNotch: ((DropyAnimation, Double) -> TimeInterval)?
    var use: ((String) -> Void)?
    var inUse: () -> Bool = { false }

    private var undoStack: [DropyAnimation] = []
    private var redoStack: [DropyAnimation] = []
    private var gestureStart: DropyAnimation?
    private var saveTask: Task<Void, Never>?
    private var autoplayTask: Task<Void, Never>?
    private var written: Data?
    private var observation: AnyCancellable?

    init(library: AnimationLibrary, fileID: String, animation: DropyAnimation) {
        self.library = library
        self.fileID = fileID
        self.animation = animation
        written = AnimationFile.data(for: animation)
        validate()
        observation = library.$entries.dropFirst().sink { [weak self] entries in
            Task { @MainActor in self?.fileChanged(entries) }
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var errors: [AnimationIssue] { issues.filter { $0.severity == .error } }
    var warnings: [AnimationIssue] { issues.filter { $0.severity == .warning } }

    // MARK: Editing

    /// A complete change, such as a menu choice: one undo step, saved, and the edited
    /// motion played.
    func edit(_ change: (inout DropyAnimation) -> Void) {
        if gestureStart != nil { return live(change) }
        var next = animation
        change(&next)
        guard next != animation else { return }
        undoStack.append(animation)
        redoStack.removeAll()
        apply(next)
        scheduleAutoplay()
    }

    /// The start of a drag or a slider move: everything until `endGesture` is one undo step.
    func beginGesture() {
        if gestureStart == nil { gestureStart = animation }
    }

    /// A step of a drag: shown at once, saved shortly after.
    func live(_ change: (inout DropyAnimation) -> Void) {
        guard gestureStart != nil else { return edit(change) }
        var next = animation
        change(&next)
        guard next != animation else { return }
        apply(next)
    }

    func endGesture() {
        guard let start = gestureStart else { return }
        gestureStart = nil
        guard start != animation else { return }
        undoStack.append(start)
        redoStack.removeAll()
        scheduleAutoplay()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(animation)
        selectedKey = nil
        apply(previous)
        scheduleAutoplay()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(animation)
        selectedKey = nil
        apply(next)
        scheduleAutoplay()
    }

    private func apply(_ next: DropyAnimation) {
        animation = next
        validate()
        scheduleSave()
    }

    private func validate() {
        issues = AnimationFile.read(AnimationFile.data(for: animation)).issues
    }

    // MARK: The current curve

    var part: DropyAnimation.Part? { tab.part }
    var motion: NotchMorph.Motion? { part.map { animation[$0] } }

    var curve: MotionCurve? {
        guard let motion else { return nil }
        return channel == .width ? motion.width : motion.height
    }

    func curve(_ channel: Channel) -> MotionCurve? {
        guard let motion else { return nil }
        return channel == .width ? motion.width : motion.height
    }

    /// Replaces the current part's curve for `channel` (the selected one by default).
    func setCurve(_ curve: MotionCurve, for channel: Channel? = nil, live isLive: Bool = false) {
        guard let part else { return }
        let target = channel ?? self.channel
        let change: (inout DropyAnimation) -> Void = { animation in
            if target == .width { animation[part].width = curve } else { animation[part].height = curve }
        }
        if isLive { live(change) } else { edit(change) }
    }

    var keys: [MotionKeyframe]? {
        if case .keyframes(let keys) = curve { return keys }
        return nil
    }

    var spring: (spring: MorphSpring, delay: TimeInterval)? {
        if case .spring(let spring, let delay) = curve { return (spring, delay) }
        return nil
    }

    /// Switches the current curve between a spring and keyframes, keeping its shape.
    func setKind(keyframes: Bool) {
        guard let curve else { return }
        switch (curve, keyframes) {
        case (.spring, true):
            setCurve(.keyframes(curve.asKeyframes()))
        case (.keyframes, false):
            // The spring that settles in about the same time, without a bounce to start.
            let response = min(max(curve.duration / 1.4, AnimationLimits.response.lowerBound), AnimationLimits.response.upperBound)
            setCurve(.spring(MorphSpring(response: response, dampingRatio: 0.85)))
        default: break
        }
        selectedKey = nil
    }

    func updateSpring(response: Double? = nil, damping: Double? = nil, delay: Double? = nil) {
        guard let current = spring else { return }
        let spring = MorphSpring(response: response ?? current.spring.response,
                                 dampingRatio: damping ?? current.spring.dampingRatio)
        setCurve(.spring(spring, delay: delay ?? current.delay), live: true)
    }

    /// Moves keyframe `index`, keeping it between its neighbors; the first stays at 0
    /// and the last at 1.
    func moveKey(_ index: Int, time: Double? = nil, value: Double? = nil, ease: MotionEase? = nil) {
        guard var keys, keys.indices.contains(index) else { return }
        var key = keys[index]
        if let time {
            let low = index > 0 ? keys[index - 1].time + 0.005 : AnimationLimits.keyTime.lowerBound
            let high = index < keys.count - 1 ? keys[index + 1].time - 0.005 : AnimationLimits.keyTime.upperBound
            key.time = (min(max(time, low), max(low, high)) * 1000).rounded() / 1000
        }
        if let value, index > 0, index < keys.count - 1 {
            key.value = (min(max(value, AnimationLimits.keyValue.lowerBound), AnimationLimits.keyValue.upperBound) * 1000).rounded() / 1000
        }
        if let ease { key.ease = ease }
        keys[index] = key
        setCurve(.keyframes(keys), live: true)
    }

    /// Adds a keyframe at `time` (with `value`, or the curve's value there) and selects it.
    func addKey(time: Double, value: Double? = nil) {
        var keys = keys ?? curve?.asKeyframes() ?? []
        guard keys.count < AnimationLimits.keyCount.upperBound, let curve else { return }
        let time = (min(max(time, 0.005), AnimationLimits.keyTime.upperBound) * 1000).rounded() / 1000
        let value = ((value ?? curve.value(at: time)) * 1000).rounded() / 1000
        if let last = keys.last, time > last.time {
            // Past the end: the new key becomes the end, and the old end a point on the way.
            keys.append(MotionKeyframe(time: time, value: 1, ease: .smooth))
            keys[keys.count - 2].value = min(max(value, AnimationLimits.keyValue.lowerBound), AnimationLimits.keyValue.upperBound)
            setCurve(.keyframes(keys))
            selectedKey = keys.count - 2
            return
        }
        guard !keys.contains(where: { abs($0.time - time) < 0.005 }) else { return }
        let index = keys.firstIndex { $0.time > time } ?? keys.count
        let clamped = index == 0 ? 0 : min(max(value, AnimationLimits.keyValue.lowerBound), AnimationLimits.keyValue.upperBound)
        keys.insert(MotionKeyframe(time: time, value: clamped, ease: .smooth), at: index)
        if index == 0, keys.count > 1 { keys[1].ease = .smooth }
        setCurve(.keyframes(keys))
        selectedKey = index
    }

    func deleteKey(_ index: Int) {
        guard var keys, keys.count > AnimationLimits.keyCount.lowerBound, index > 0, index < keys.count - 1 else { return }
        keys.remove(at: index)
        setCurve(.keyframes(keys))
        selectedKey = nil
    }

    /// Replaces the current curve with a drawn stroke (time in seconds, progress).
    func applyStroke(_ points: [(time: Double, value: Double)]) {
        guard points.count > 2 else { return }
        setCurve(.keyframes(CurveSketch.keyframes(from: points)))
        selectedKey = nil
    }

    /// Gives the other part the same curve.
    func copyCurveToOtherChannel() {
        guard let curve else { return }
        setCurve(curve, for: channel == .width ? .height : .width)
    }

    /// Replaces the current part (or the content) with a built-in style's or an example's.
    func reset(to source: DropyAnimation) {
        edit { animation in
            if let part = tab.part { animation[part] = source[part] } else { animation.content = source.content }
        }
    }

    func editContent(live isLive: Bool = false, _ change: @escaping (inout ContentMotion) -> Void) {
        let edit: (inout DropyAnimation) -> Void = { change(&$0.content) }
        if isLive { live(edit) } else { self.edit(edit) }
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit { $0.name = trimmed }
    }

    func describe(_ summary: String, author: String) {
        edit {
            $0.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: Playing

    func play(_ parts: [DropyAnimation.Part] = DropyAnimation.Part.allCases) {
        autoplayTask?.cancel()
        playParts = parts
        playRequest += 1
    }

    /// Plays the motion being edited (all of it for the content).
    func playCurrent() { play(part.map { [$0] } ?? DropyAnimation.Part.allCases) }

    /// After an edit settles, play what changed, unless a loop is already showing it.
    private func scheduleAutoplay() {
        guard !loop else { return play() }
        autoplayTask?.cancel()
        autoplayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            self?.playCurrent()
        }
    }

    func partStarted(_ part: DropyAnimation.Part?, at time: CFTimeInterval, slowdown: Double) {
        playing = part.map { ($0, time, slowdown) }
    }

    func playOnNotchNow() { _ = playOnNotch?(animation, slowdown) }

    // MARK: The file

    var url: URL { library.folder.appendingPathComponent("\(fileID).json") }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let data = AnimationFile.data(for: animation)
        guard data != written else { return }
        do {
            try FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            written = data
            fileMissing = false
            library.scan()
        } catch {
            NSLog("Dropy studio: cannot save %@: %@", url.path, error.localizedDescription)
        }
    }

    /// The file changed on disk: take an outside edit in (it can be undone), or note
    /// that the file went away.
    private func fileChanged(_ entries: [AnimationLibrary.Entry]) {
        guard let entry = entries.first(where: { $0.id == fileID }) else {
            fileMissing = true
            return
        }
        fileMissing = false
        guard gestureStart == nil, let data = try? Data(contentsOf: entry.url), data != written else { return }
        written = data
        guard let outside = entry.animation, outside != animation else { return }
        undoStack.append(animation)
        redoStack.removeAll()
        animation = outside
        selectedKey = nil
        validate()
        play()
    }

    func copyShareCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AnimationFile.shareCode(for: animation), forType: .string)
        shareCodeCopied = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.shareCodeCopied = false
        }
    }

    /// A prompt for an AI agent to refine this very file.
    func copyRefinePrompt() {
        let prompt = """
            Refine my Dropy animation in \(url.path).

            What to change: <describe it here>

            Read \(library.folder.path)/README.md first: it explains the format and the rules.
            Check it with: \(AnimationLibrary.command) check "\(url.path)"
            Look at it with: \(AnimationLibrary.command) render "\(url.path)" --out /tmp/dropy-animation.png
            Show me on the notch with: \(AnimationLibrary.command) play "\(url.path)"
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }
}

/// The Animation Studio window. One file is open at a time; opening another replaces it.
@MainActor
final class AnimationStudioController: NSObject, NSWindowDelegate {
    private let library: AnimationLibrary
    private var window: NSWindow?
    private(set) var model: AnimationStudioModel?
    var playOnNotch: ((DropyAnimation, Double) -> TimeInterval)?
    var use: ((String) -> Void)?
    var inUse: (String) -> Bool = { _ in false }
    /// Called when the window appears or closes (for the Dock icon).
    var onVisibilityChange: (() -> Void)?

    init(library: AnimationLibrary) {
        self.library = library
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Opens `fileID` (a file in the animations folder).
    func open(_ fileID: String) {
        library.scan()
        guard let entry = library.entry(fileID) else { return }
        guard let animation = entry.animation else {
            // A file with errors opens in the editor the person wrote it with.
            NSWorkspace.shared.open(entry.url)
            return
        }
        model?.saveNow()
        let model = AnimationStudioModel(library: library, fileID: fileID, animation: animation)
        model.playOnNotch = playOnNotch
        model.use = use
        model.inUse = { [weak self] in self?.inUse(fileID) ?? false }
        self.model = model
        let window = self.window ?? makeWindow()
        let host = NSHostingController(rootView: AnimationStudioView(model: model))
        // The window keeps the size the person gave it; SwiftUI content does not resize it.
        host.sizingOptions = []
        let frame = window.frame
        window.contentViewController = host
        if self.window != nil { window.setFrame(frame, display: false) }
        window.title = "\(animation.name) — Animation Studio"
        if self.window == nil {
            window.setContentSize(CGSize(width: 1120, height: 760))
            window.center()
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onVisibilityChange?()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 980, height: 660)
        window.setFrameAutosaveName("DropyAnimationStudio")
        window.delegate = self
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.155, green: 0.155, blue: 0.162, alpha: 1)
                : NSColor(srgbRed: 0.940, green: 0.940, blue: 0.945, alpha: 1)
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model?.saveNow()
        DispatchQueue.main.async { [weak self] in self?.onVisibilityChange?() }
    }
}
