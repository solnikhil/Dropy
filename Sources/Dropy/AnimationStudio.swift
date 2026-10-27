import AppKit
import Combine
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
    private let fileURL: URL
    @Published private(set) var animation: DropyAnimation
    @Published var tab: Tab = .open { didSet { if tab != oldValue { selectedKey = nil } } }
    @Published var channel: Channel = .height { didSet { if channel != oldValue { selectedKey = nil } } }
    @Published var selectedKey: Int?
    @Published var tool: Tool = .select
    /// A built-in style whose curve is drawn faintly behind the one being edited.
    @Published var reference: MotionStyle?
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
    private var savedAnimation: DropyAnimation
    private var deferredFileChange: [AnimationLibrary.Entry]?
    private var observation: AnyCancellable?

    init(library: AnimationLibrary, fileID: String, animation: DropyAnimation) {
        self.library = library
        self.fileID = fileID
        fileURL = library.entry(fileID)?.url ?? library.folder.appendingPathComponent("\(fileID).json")
        self.animation = animation
        savedAnimation = animation
        written = library.entry(fileID)?.contents ?? AnimationFile.data(for: animation)
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
        defer {
            if let pending = deferredFileChange {
                deferredFileChange = nil
                fileChanged(pending)
            }
        }
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
        if let time, time.isFinite {
            let lower = index > 0 ? keys[index - 1].time + 0.001 : AnimationLimits.keyTime.lowerBound
            let upper = index < keys.count - 1 ? keys[index + 1].time - 0.001 : AnimationLimits.keyTime.upperBound
            // Drag times use milliseconds. An imported curve may have tighter
            // spacing; if no grid point fits, preserve its time instead of crossing
            // a neighbor. Value/ease edits can still proceed.
            let low = ceil(lower * 1000 - 1e-9) / 1000
            let high = floor(upper * 1000 + 1e-9) / 1000
            if low <= high {
                key.time = (min(max(time, low), high) * 1000).rounded() / 1000
            }
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

    /// Makes the closing the opening played backwards (both parts).
    func mirrorOpening() {
        edit { animation in
            animation.close.width = animation.open.width.reversed()
            animation.close.height = animation.open.height.reversed()
        }
    }

    /// Opens another animation file in the Studio.
    var openFile: ((String) -> Void)?

    /// Saves a copy (or a new animation starting as this one) and opens it.
    func duplicate(named name: String? = nil) {
        saveNow()
        var copy = animation
        copy.name = name ?? "\(animation.name) Copy"
        let id = library.freeID(for: copy.name)
        if name != nil { copy.name = AnimationLibrary.title(for: id) }
        do {
            try library.save(copy, as: id)
            openFile?(id)
        } catch {
            NSLog("Dropy studio: cannot save a copy: %@", error.localizedDescription)
        }
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

    var url: URL { fileURL }

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
        saveTask = nil
        if !fileMissing && !FileManager.default.fileExists(atPath: url.path) {
            noteMissingFile()
            library.scan()
            return
        }
        guard animation != savedAnimation else { return }
        if FileManager.default.fileExists(atPath: url.path), AnimationLibrary.data(at: url) != written {
            // Catch outside edits even before the watcher has delivered them.
            // Refresh the model rather than overwriting a newer disk version.
            library.scan()
            fileChanged(library.entries)
            return
        }
        let data = AnimationFile.data(for: animation)
        do {
            try FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            written = data
            savedAnimation = animation
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
            noteMissingFile()
            return
        }
        fileMissing = false
        let data = entry.contents
        guard data != written else { return }
        saveTask?.cancel()
        saveTask = nil
        if gestureStart != nil {
            deferredFileChange = entries
            return
        }
        written = data
        savedAnimation = animation
        issues = entry.result.issues
        guard let outside = entry.animation, outside != animation else { return }
        undoStack.append(animation)
        redoStack.removeAll()
        animation = outside
        savedAnimation = outside
        selectedKey = nil
        play()
    }

    private func noteMissingFile() {
        fileMissing = true
        saveTask?.cancel()
        saveTask = nil
        deferredFileChange = nil
        written = nil
        // Keep pending work in the model for Save a Copy, but do not recreate a
        // deleted file on close or on an old timer. A subsequent explicit edit
        // changes this baseline and can save it again, as the banner promises.
        savedAnimation = animation
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
        let file = library.quotedPath(for: fileID)
        let prompt = """
            Refine my Dropy animation in \(file).

            What to change: <describe it here>

            Read \(library.shownFolder)/README.md first: it explains the format and the rules.
            Check it with: \(AnimationLibrary.command) check \(file)
            Look at it with: \(AnimationLibrary.command) render \(file) --out /tmp/dropy-animation.png
            Show me on the notch with: \(AnimationLibrary.command) play \(file)
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }
}
