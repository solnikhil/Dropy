import AppKit
import SwiftUI
import DropyCore

/// Replays the preview on request (an object: the local build has no State macro).
@MainActor
final class ReplayCounter: ObservableObject {
    @Published var count = 0
}

/// Settings › Animation: the animation in use, playing; the built-in styles; the
/// person's own animations; and the ways to make one (the Studio, an example, a share
/// code, or an AI agent).
struct AnimationSettingsPage: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var replay = ReplayCounter()

    private var choice: AnimationLibrary.Choice { model.animationChoice }

    var body: some View {
        SettingsPage {
            if let problem = choice.problem {
                SettingsCard {
                    SettingsNotice(symbol: "exclamationmark.triangle.fill", title: "Your animation can't be used right now",
                                   detail: problem) {
                        if let id = model.preferences.customAnimation, model.animations?.entry(id) != nil {
                            Button("Fix It") { model.openStudio?(id) }.buttonStyle(SettingsButtonStyle())
                        }
                    }
                }
            }
            preview
            SettingsCard("Built In") {
                SettingsRow("Style", detail: model.preferences.customAnimation == nil
                            ? model.preferences.motionStyle.summary
                            : "Your own animation is in use. Choose a style here to go back to one.") {
                    SettingsChoiceTiles(label: "Animation style", selection: Binding(
                        get: { model.preferences.customAnimation == nil ? Optional(model.preferences.motionStyle) : nil },
                        set: { if let style = $0 { model.useBuiltIn(style) } }), options: [
                        ("Rapid", Optional(MotionStyle.rapid), "Quick and direct"),
                        ("Balanced", Optional(MotionStyle.balanced), "Smooth but quick"),
                        ("Smooth", Optional(MotionStyle.smooth), "Unhurried, with a soft settle"),
                    ])
                }
            }
            yours
            ai
        }
    }

    // MARK: Preview

    private var preview: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowInset) {
                // Ends open, so the preview at rest shows the overlay rather than an empty notch.
                AnimationStage(animation: choice.animation, request: replay.count, parts: [.open, .resize, .close, .open])
                    .frame(height: 190)
                HStack(alignment: .center, spacing: SettingsMetrics.rowInset) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: SettingsMetrics.controlSpacing) {
                            Text(choice.animation.name).font(SettingsMetrics.bodyEmphasis)
                            SettingsBadge(choice.animation.cost.level.title)
                                .help(choice.animation.cost.reason)
                        }
                        Text(DropyAnimation.Part.allCases.map { String(format: "%@ %.2f s", $0.title, choice.animation[$0].duration) }
                            .joined(separator: " · "))
                            .font(SettingsMetrics.detail.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { replay.count += 1 } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(SettingsButtonStyle(circular: true))
                        .help("Replay")
                    Button("Play on Notch") { _ = model.playOnNotch?(choice.animation, 1) }
                        .buttonStyle(SettingsButtonStyle())
                        .help("Play it for real at the notch, with stand-in content")
                }
            }
            .padding(SettingsMetrics.rowInset)
        }
    }

    // MARK: Yours

    private var yours: some View {
        SettingsCard("Yours", footer: "Each is a file in the animations folder. Dropy picks up a change the moment the file is saved, so edits from a text editor or an AI agent show up here at once.") {
            if model.animationEntries.isEmpty {
                SettingsRow("No animations of your own yet",
                            detail: "Make one in the Animation Studio, start from an example, paste a share code, or ask an AI agent.")
            }
            ForEach(model.animationEntries) { entry in row(entry) }
            HStack(spacing: SettingsMetrics.controlSpacing) {
                Button("New Animation…") { model.newAnimation() }
                    .buttonStyle(SettingsButtonStyle(outlined: true))
                    .help("Starts as the animation in use and opens the Animation Studio")
                Menu("Start from an Example") {
                    ForEach(DropyAnimation.gallery, id: \.id) { example in
                        Button(example.animation.name) { model.addExample(example.id) }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(SettingsButtonStyle())
                .fixedSize()
                Button("Paste Share Code") { model.pasteShareCode() }
                    .buttonStyle(SettingsButtonStyle())
                Button { model.surpriseMe() } label: { Image(systemName: "dice") }
                    .buttonStyle(SettingsButtonStyle(circular: true))
                    .help("Surprise me: a new animation made at random, to start from")
                Spacer()
                Button { model.showAnimationsFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(SettingsButtonStyle(circular: true))
                    .help("Show the animations folder in Finder")
            }
            .settingsRow()
            if let message = model.animationMessage {
                SettingsFootnote(message).settingsRow()
            }
        }
    }

    private func row(_ entry: AnimationLibrary.Entry) -> some View {
        let inUse = model.isInUse(entry.id)
        let errors = entry.result.errors
        let detail = errors.first.map { "\($0.path.isEmpty ? "" : $0.path + ": ")\($0.message)" }
            ?? (entry.animation?.summary.isEmpty == false ? entry.animation!.summary : "\(entry.id).json")
        return HStack(spacing: SettingsMetrics.rowInset) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SettingsMetrics.controlSpacing) {
                    Text(entry.name).font(SettingsMetrics.body)
                    if inUse { SettingsBadge("In Use") }
                    if !errors.isEmpty { SettingsBadge("Has Problems") }
                }
                Text(detail).font(SettingsMetrics.detail).foregroundStyle(errors.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SettingsMetrics.rowInset)
            if !inUse, errors.isEmpty {
                Button("Use") { model.useAnimation(entry.id) }.buttonStyle(SettingsButtonStyle())
            }
            Button(errors.isEmpty ? "Edit" : "Fix") { model.openStudio?(entry.id) }
                .buttonStyle(SettingsButtonStyle())
                .help(errors.isEmpty ? "Open in the Animation Studio" : "Open the file to fix it")
            Menu {
                if let animation = entry.animation {
                    Button("Play on Notch") { _ = model.playOnNotch?(animation, 1) }
                    Button("Duplicate") { model.duplicate(entry.id) }
                    Button("Copy Share Code") { model.copyShareCode(entry.id) }
                }
                Button("Show in Finder") { model.showInFinder(entry.id) }
                Divider()
                Button("Move to Trash") { model.deleteAnimation(entry.id) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button)
                .buttonStyle(SettingsButtonStyle(circular: true))
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .settingsRow()
    }

    // MARK: AI

    private var ai: some View {
        SettingsCard("Make One with AI", footer: "The prompt points the agent at the guide in the animations folder, which explains the format and the rules. The agent writes a file there, checks it, draws it, and plays it on your notch until you like it.") {
            SettingsRow("Copy a Prompt", detail: "Paste it into Claude Code, Codex, Cursor or another agent that can run commands, and describe the feel you want.") {
                Button(model.promptCopied ? "Copied" : "Copy Prompt") { model.copyAIPrompt() }
                    .buttonStyle(SettingsButtonStyle(outlined: true))
            }
            SettingsRow("Command Line", detail: "Check, draw, play and share animations from a terminal: \(AnimationLibrary.command) help") {
                Button("Copy") { model.copyAnimationCommand() }
                    .buttonStyle(SettingsButtonStyle())
            }
        }
    }
}
