import AppKit
import SwiftUI
import DropyCore

/// Text being typed in the Studio, committed when the typing pauses or Return is
/// pressed, so a name is one undo step rather than one per letter.
@MainActor
final class StudioForm: ObservableObject {
    @Published var name: String?
    @Published var showsDetails = false
    @Published var showsIssues = false
    @Published var summary = ""
    @Published var author = ""
    private var commit: Task<Void, Never>?

    func typed(_ text: String, model: AnimationStudioModel) {
        name = text
        commit?.cancel()
        commit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.commitName(model)
        }
    }

    func commitName(_ model: AnimationStudioModel) {
        commit?.cancel()
        if let name { model.rename(name) }
        name = nil
    }
}

struct AnimationStudioView: View {
    @ObservedObject var model: AnimationStudioModel
    @StateObject private var form = StudioForm()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if reduceMotion || model.fileMissing { banner }
                AnimationStage(animation: model.animation, request: model.playRequest, parts: model.playParts,
                               slowdown: model.slowdown, loop: model.loop, autoplay: false) { part, time, slowdown in
                    model.partStarted(part, at: time, slowdown: slowdown)
                }
                .frame(minHeight: 200, idealHeight: 250, maxHeight: 270)
                tabs
                Group {
                    if model.tab == .content {
                        contentArea
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            MotionGraph(model: model)
                            Text(graphHint).font(SettingsMetrics.detail).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                statusBar
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            Rectangle().fill(SettingsTheme.separator).frame(width: 1)
            inspector
                .frame(width: 310)
        }
        .background(SettingsTheme.background)
        .onAppear { model.play([.open, .resize, .close, .open]) }
        .onDisappear { form.commitName(model) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Name", text: Binding(get: { form.name ?? model.animation.name },
                                           set: { form.typed($0, model: model) }))
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .frame(minWidth: 150, maxWidth: 260)
                .layoutPriority(1)
                .onSubmit { form.commitName(model) }
            Button {
                form.summary = model.animation.summary
                form.author = model.animation.author
                form.showsDetails = true
            } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Description and author")
                .popover(isPresented: $form.showsDetails, arrowEdge: .bottom) { details }
            Spacer(minLength: 12)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(SettingsButtonStyle(circular: true))
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(SettingsButtonStyle(circular: true))
                .disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo (⇧⌘Z)")
            Button { model.play() } label: { Label("Play All", systemImage: "play.fill") }
                .buttonStyle(SettingsButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .help("Play opening, resizing and closing (⌘↩)")
            if model.inUse() {
                Label("In Use", systemImage: "checkmark.circle.fill")
                    .font(SettingsMetrics.body)
                    .foregroundStyle(.secondary)
            } else {
                Button("Use Animation") {
                    model.saveNow()
                    model.use?(model.fileID)
                    model.objectWillChange.send()
                }
                .buttonStyle(SettingsButtonStyle(outlined: true))
                .disabled(!model.errors.isEmpty || model.fileMissing)
                .help("Make the overlay use this animation")
            }
            Menu {
                Button("Play on Notch") { model.playOnNotchNow() }
                Divider()
                Button(model.shareCodeCopied ? "Share Code Copied" : "Copy Share Code") { model.copyShareCode() }
                Button("Copy AI Prompt to Refine It") { model.copyRefinePrompt() }
                Divider()
                Button("Duplicate") { model.duplicate() }
                Button("New Animation from This") { model.duplicate(named: "My Animation") }
                Divider()
                Button("Show in Finder") {
                    model.saveNow()
                    NSWorkspace.shared.activateFileViewerSelecting([model.url])
                }
                Button("Open in Text Editor") {
                    model.saveNow()
                    NSWorkspace.shared.open(model.url)
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button)
                .buttonStyle(SettingsButtonStyle(circular: true))
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .padding(.leading, 70)
        .frame(height: 52)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Description").font(SettingsMetrics.bodyEmphasis)
            TextEditor(text: $form.summary)
                .font(SettingsMetrics.body)
                .frame(width: 320, height: 80)
                .scrollContentBackground(.hidden)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            Text("Author").font(SettingsMetrics.bodyEmphasis)
            TextField("Your name", text: $form.author)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Done") {
                    model.describe(form.summary, author: form.author)
                    form.showsDetails = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: model.fileMissing ? "exclamationmark.triangle.fill" : "figure.walk.motion")
                .foregroundStyle(model.fileMissing ? .orange : .secondary)
            Text(model.fileMissing
                 ? "This file is no longer in the animations folder. Any change saves it again."
                 : "Reduce Motion is on, so the overlay uses a short fade instead. The Studio still plays your animation.")
                .font(SettingsMetrics.detail)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 12) {
            // ⌘1–⌘4 switch motions (invisible buttons that only carry the shortcuts).
            ForEach(Array(AnimationStudioModel.Tab.allCases.enumerated()), id: \.offset) { index, tab in
                Button("") { model.tab = tab }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            Picker("Motion", selection: $model.tab) {
                ForEach(AnimationStudioModel.Tab.allCases) { tab in Text(tab.title).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            if model.tab != .content {
                Picker("Tool", selection: $model.tool) {
                    Image(systemName: "cursorarrow").help("Select and drag").tag(AnimationStudioModel.Tool.select)
                    Image(systemName: "pencil.and.scribble").help("Draw a curve").tag(AnimationStudioModel.Tool.draw)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 72)
                Button { model.playCurrent() } label: { Label("Play \(model.tab.title)", systemImage: "play") }
                    .buttonStyle(SettingsButtonStyle())
                    .help("Play only the \(model.tab.rawValue) motion")
                    .padding(.trailing, 4)
                playbackOptions
                Spacer(minLength: 0)
                Menu {
                    Button("Nothing") { model.reference = nil }
                    ForEach(MotionStyle.allCases, id: \.self) { style in
                        Button(style.title) { model.reference = style }
                    }
                } label: {
                    Text(model.reference.map { "Compare: \($0.title)" } ?? "Compare")
                }
                .menuStyle(.button)
                .buttonStyle(SettingsButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Draw a built-in style's curve behind yours")
            } else {
                playbackOptions
                Spacer()
            }
        }
    }

    /// Slow motion and looping, for the stage and the notch.
    private var playbackOptions: some View {
        HStack(spacing: 6) {
            SettingsMenu(label: "Playback speed", selection: $model.slowdown, options: [
                ("1×", 1.0), ("½×", 2.0), ("¼×", 4.0), ("⅒×", 10.0),
            ])
            .help("Slow motion, here and on the notch")
            Toggle(isOn: $model.loop) { Image(systemName: "repeat") }
                .toggleStyle(.button)
                .help("Play over and over")
        }
    }

    private var graphHint: String {
        if model.tool == .draw {
            return "Draw the \(model.channel.rawValue) curve from left to right with the pen; Dropy smooths it into keyframes."
        }
        if model.spring != nil {
            return "Drag the round handle sideways for speed and up for bounce (or click the graph and use the arrow keys); the square sets a delay."
        }
        return "Drag points, or click one and use the arrow keys (Shift for bigger steps; Tab for the next). Double-click adds a point; Delete removes it."
    }

    // MARK: Content

    private var contentArea: some View {
        VStack(spacing: 12) {
            ContentTimeline(animation: model.animation)
                .frame(minHeight: 170, maxHeight: 240)
            HStack(alignment: .top, spacing: 16) {
                TimingCurveEditor(title: "Coming in", curve: model.animation.content.revealCurve,
                                  onBegin: { model.beginGesture() },
                                  onChange: { curve in model.editContent(live: true) { $0.revealCurve = curve } },
                                  onEnd: { model.endGesture() })
                TimingCurveEditor(title: "Going out", curve: model.animation.content.hideCurve,
                                  onBegin: { model.beginGesture() },
                                  onChange: { curve in model.editContent(live: true) { $0.hideCurve = curve } },
                                  onEnd: { model.endGesture() })
            }
            .frame(maxHeight: 220)
        }
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 8) {
            let errors = model.errors.count
            let warnings = model.warnings.count
            Image(systemName: errors > 0 ? "xmark.octagon.fill" : warnings > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(errors > 0 ? Color.red : warnings > 0 ? Color.orange : Color.green)
            Text(errors > 0 ? "\(errors) problem\(errors == 1 ? "" : "s"): the overlay can't use it yet"
                 : warnings > 0 ? "Works, with \(warnings) note\(warnings == 1 ? "" : "s")" : "Ready to use")
                .font(SettingsMetrics.detail)
            if !model.issues.isEmpty {
                Button("Details") { form.showsIssues = true }
                    .buttonStyle(.link)
                    .font(SettingsMetrics.detail)
                    .popover(isPresented: $form.showsIssues, arrowEdge: .top) { issueList }
            }
            Text("·").foregroundStyle(.tertiary)
            Text(DropyAnimation.Part.allCases.map { String(format: "%@ %.2f s", $0.title, model.animation[$0].duration) }
                .joined(separator: "  "))
                .font(SettingsMetrics.detail.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            let cost = model.animation.cost
            Text(cost.level.title)
                .font(SettingsMetrics.badge)
                .foregroundStyle(cost.level == .heavy ? Color.orange : SettingsTheme.badge)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background((cost.level == .heavy ? Color.orange : SettingsTheme.badge).opacity(0.15), in: Capsule())
                .help(cost.reason)
            Text("\(model.fileID).json")
                .font(SettingsMetrics.detail)
                .foregroundStyle(.tertiary)
        }
    }

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        if !issue.path.isEmpty {
                            Text(issue.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Text(issue.message).font(SettingsMetrics.detail).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Fine-tune").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("Small changes. A different feel.").font(SettingsMetrics.detail).foregroundStyle(.secondary)
                }
                if model.tab == .content { contentInspector } else { curveInspector }
            }
            .padding(.horizontal, 18)
            .padding(.top, 58)
            .padding(.bottom, 18)
        }
        .background(SettingsTheme.sidebar.opacity(0.45))
    }

    @ViewBuilder private var curveInspector: some View {
        StudioSection(model.tab.title) {
            Text(partDetail).font(SettingsMetrics.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        StudioSection("Part") {
            Picker("Part", selection: $model.channel) {
                ForEach(AnimationStudioModel.Channel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.channel.detail).font(SettingsMetrics.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        StudioSection("Curve") {
            Picker("Curve", selection: Binding(get: { model.keys != nil }, set: { model.setKind(keyframes: $0) })) {
                Text("Spring").tag(false)
                Text("Keyframes").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let spring = model.spring {
                springControls(spring.spring, delay: spring.delay)
            } else if let keys = model.keys {
                keyframeControls(keys)
            }
        }
        StudioSection("Both Parts") {
            Button("Use This Curve for \(model.channel == .width ? "Height" : "Width")") { model.copyCurveToOtherChannel() }
                .buttonStyle(SettingsButtonStyle())
            startFromMenu
        }
        if model.tab == .close {
            Button("Mirror the Opening") { model.mirrorOpening() }
                .buttonStyle(SettingsButtonStyle())
                .help("Make the closing the opening played backwards")
            Text("Closing is forward-only: it can never bounce back out of the notch. A dashed line shows a curve as written when that changes it.")
                .font(SettingsMetrics.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var partDetail: String {
        switch model.tab {
        case .open: "Out of the notch to the open overlay."
        case .resize: "From one open size to another, as when the window list gives way to the window you chose."
        case .close: "Back into the notch."
        case .content: ""
        }
    }

    private func springControls(_ spring: MorphSpring, delay: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioSlider("Response", value: spring.response, in: AnimationLimits.response, format: "%.2f s",
                         detail: "Seconds for one swing; smaller is faster.", model: model) { model.updateSpring(response: $0) }
            StudioSlider("Bounce", value: 1 - spring.dampingRatio,
                         in: (1 - AnimationLimits.damping.upperBound)...(1 - AnimationLimits.damping.lowerBound),
                         format: "%.0f %%", scale: 100, detail: "0 settles without overshooting.", model: model) {
                model.updateSpring(damping: 1 - $0)
            }
            StudioSlider("Delay", value: delay, in: AnimationLimits.delay, format: "%.2f s",
                         detail: "Waits this long before moving.", model: model) { model.updateSpring(delay: $0) }
            Text(String(format: "Settles after %.2f s.", MotionCurve.spring(spring, delay: delay).duration))
                .font(SettingsMetrics.detail).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func keyframeControls(_ keys: [MotionKeyframe]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                Button { model.selectedKey = index } label: {
                    HStack {
                        Text("\(index + 1)").foregroundStyle(.tertiary).frame(width: 18, alignment: .leading)
                        Text(String(format: "%.2f s", key.time)).frame(width: 56, alignment: .leading)
                        Text(String(format: "%.0f %%", key.value * 100)).frame(width: 48, alignment: .leading)
                        Text(index == 0 ? "start" : easeTitle(key.ease)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(SettingsMetrics.detail.monospacedDigit())
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(model.selectedKey == index ? SettingsTheme.selection : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        HStack {
            Button("Add Keyframe") {
                let index = model.selectedKey ?? (keys.count - 2)
                let next = min(index + 1, keys.count - 1)
                model.addKey(time: (keys[max(index, 0)].time + keys[next].time) / 2)
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(keys.count >= AnimationLimits.keyCount.upperBound)
            Button("Delete") { if let index = model.selectedKey { model.deleteKey(index) } }
                .buttonStyle(SettingsButtonStyle())
                .disabled(model.selectedKey.map { $0 == 0 || $0 == keys.count - 1 } ?? true)
        }
        if let index = model.selectedKey, keys.indices.contains(index) {
            let key = keys[index]
            VStack(alignment: .leading, spacing: 12) {
                StudioSlider("Time", value: key.time, in: AnimationLimits.keyTime.lowerBound...min(AnimationLimits.keyTime.upperBound, 1.6),
                             format: "%.2f s", model: model) { model.moveKey(index, time: $0) }
                if index > 0, index < keys.count - 1 {
                    StudioSlider("Value", value: key.value, in: AnimationLimits.keyValue, format: "%.0f %%", scale: 100,
                                 detail: "100 % is the end; above it overshoots.", model: model) { model.moveKey(index, value: $0) }
                } else {
                    Text(index == 0 ? "The first keyframe is where the motion starts (0 %); a later time waits."
                                    : "The last keyframe is where the motion ends (100 %).")
                        .font(SettingsMetrics.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if index > 0 { easeControls(index: index, ease: key.ease) }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder private func easeControls(index: Int, ease: MotionEase) -> some View {
        HStack {
            Text("Ease").font(SettingsMetrics.body)
            Spacer()
            Menu(easeTitle(ease)) {
                ForEach(MotionEase.names, id: \.self) { name in
                    Button(easeTitle(MotionEase(name: name) ?? .smooth)) {
                        model.beginGesture()
                        model.moveKey(index, ease: MotionEase(name: name))
                        model.endGesture()
                    }
                }
                Button("Custom Curve") {
                    model.beginGesture()
                    model.moveKey(index, ease: .curve(TimingCurve(0.3, 0.9, 0.4, 1.12)))
                    model.endGesture()
                }
            }
            .fixedSize()
        }
        Text("How the curve travels from the previous keyframe to this one.")
            .font(SettingsMetrics.detail).foregroundStyle(.secondary)
        if case .curve(let curve) = ease, ease.name == nil {
            TimingCurveEditor(title: "Custom curve", curve: curve,
                              onBegin: { model.beginGesture() },
                              onChange: { model.moveKey(index, ease: .curve($0)) },
                              onEnd: { model.endGesture() })
                .frame(maxWidth: 220)
        }
    }

    private func easeTitle(_ ease: MotionEase) -> String {
        switch ease.name {
        case "smooth": "Smooth"
        case "linear": "Linear"
        case "easeIn": "Ease In"
        case "easeOut": "Ease Out"
        case "easeInOut": "Ease In-Out"
        case "settle": "Settle"
        case "leave": "Leave"
        default: "Custom"
        }
    }

    private var startFromMenu: some View {
        Menu("Start This \(model.tab == .content ? "Content" : model.tab.title) From…") {
            ForEach(MotionStyle.allCases, id: \.self) { style in
                Button(style.title) { model.reset(to: style.animation) }
            }
            Divider()
            ForEach(DropyAnimation.gallery, id: \.id) { example in
                Button(example.animation.name) { model.reset(to: example.animation) }
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var contentInspector: some View {
        let content = model.animation.content
        StudioSection("Content") {
            Text("The window list or app inside the outline: when it comes in, how, and how it leaves.")
                .font(SettingsMetrics.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        StudioSection("Coming In") {
            StudioSlider("Appears after", value: content.revealDelay, in: AnimationLimits.revealDelay, format: "%.2f s",
                         detail: "Counted from when the outline starts to grow.", model: model) { value in
                model.editContent(live: true) { $0.revealDelay = value }
            }
            StudioSlider("Takes", value: content.revealDuration, in: AnimationLimits.revealDuration, format: "%.2f s",
                         model: model) { value in model.editContent(live: true) { $0.revealDuration = value } }
            StudioSlider("Cascade", value: content.staggerSpan, in: AnimationLimits.cascade, format: "%.2f s",
                         detail: "Lower pieces arrive up to this much later.", model: model) { value in
                model.editContent(live: true) { $0.staggerSpan = value }
            }
            StudioSlider("Drift", value: Double(content.staggerDrift), in: AnimationLimits.drift, format: "%.0f pt",
                         detail: "Each piece falls into place from this far up.", model: model) { value in
                model.editContent(live: true) { $0.staggerDrift = CGFloat(value) }
            }
            StudioSlider("Starts at", value: Double(content.restScale), in: AnimationLimits.startScale, format: "%.0f %%",
                         scale: 100, detail: "Its size as it comes in, and as it leaves.", model: model) { value in
                model.editContent(live: true) { $0.restScale = CGFloat(value) }
            }
            StudioSlider("Blur", value: Double(content.blurRadius), in: AnimationLimits.blur, format: "%.0f pt",
                         detail: "Out of focus at the start. The costly part: 0 is cheapest.", model: model) { value in
                model.editContent(live: true) { $0.blurRadius = CGFloat(value) }
            }
        }
        StudioSection("Going Out") {
            StudioSlider("Takes", value: content.hideDuration, in: AnimationLimits.hideDuration, format: "%.2f s",
                         model: model) { value in model.editContent(live: true) { $0.hideDuration = value } }
        }
        StudioSection("After a Resize") {
            StudioSlider("Fades up over", value: content.relayoutDuration, in: AnimationLimits.relayoutDuration,
                         format: "%.2f s", model: model) { value in model.editContent(live: true) { $0.relayoutDuration = value } }
        }
        StudioSection("Start From") { startFromMenu }
    }
}

/// A titled group in the inspector.
struct StudioSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(SettingsMetrics.header)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SettingsTheme.separator, lineWidth: 1) }
    }
}

/// A slider with its value, whose whole drag is one undo step.
struct StudioSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1
    var detail: String?
    let model: AnimationStudioModel
    let set: (Double) -> Void

    init(_ title: String, value: Double, in range: ClosedRange<Double>, format: String, scale: Double = 1,
         detail: String? = nil, model: AnimationStudioModel, set: @escaping (Double) -> Void) {
        self.title = title
        self.value = value
        self.range = range
        self.format = format
        self.scale = scale
        self.detail = detail
        self.model = model
        self.set = set
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(SettingsMetrics.body)
                Spacer()
                Text(String(format: format, value * scale)).font(SettingsMetrics.body.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                                  set: { set(($0 * 1000).rounded() / 1000) }),
                   in: range) { editing in
                if editing { model.beginGesture() } else { model.endGesture() }
            }
            .controlSize(.small)
            if let detail {
                Text(detail).font(SettingsMetrics.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
