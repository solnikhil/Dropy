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
            builtInStyles
            yours
            examples
            ai
        }
    }

    private var builtInStyles: some View {
        SettingsCard("Find Your Rhythm") {
            HStack(alignment: .top, spacing: 10) {
                ForEach(MotionStyle.allCases, id: \.self) { style in
                    let selected = model.preferences.customAnimation == nil && model.preferences.motionStyle == style
                    Button { model.useBuiltIn(style) } label: {
                        SettingsVisualChoice(title: style.title, subtitle: style.summary, selected: selected) {
                            MotionSparkline(motion: style.animation.open)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.title)
                    .accessibilityHint(style.summary)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(SettingsMetrics.rowInset)
        }
    }

    // MARK: Preview

    private var preview: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: SettingsMetrics.rowInset) {
                // Ends open, so the preview at rest shows the overlay rather than an empty notch.
                HStack {
                    Label("MOTION PREVIEW", systemImage: "play.rectangle")
                        .font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    Text("Open · Resize · Close").font(SettingsMetrics.detail).foregroundStyle(.secondary)
                }
                AnimationStage(animation: choice.animation, request: replay.count, parts: [.open, .resize, .close, .open])
                    .frame(height: 200)
                HStack(alignment: .center, spacing: SettingsMetrics.rowInset) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: SettingsMetrics.controlSpacing) {
                            Text(choice.animation.name).font(.system(size: 17, weight: .semibold, design: .rounded))
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
                        .buttonStyle(SettingsButtonStyle(outlined: true))
                        .help("Play it for real at the notch, with stand-in content")
                }
            }
            .padding(SettingsMetrics.rowInset)
        }
    }

    // MARK: Yours

    private var yours: some View {
        SettingsCard("Your Collection") {
            if model.animationEntries.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 24, weight: .light)).foregroundStyle(SettingsTheme.accent)
                        .frame(width: 46, height: 46)
                        .background(SettingsTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    SettingsLabel("A movement of your own", detail: "Shape a spring, draw a curve, or start with an example.")
                }
                .settingsRow()
            }
            ForEach(model.animationEntries) { entry in row(entry) }
            HStack(spacing: SettingsMetrics.controlSpacing) {
                Button("New Animation…") { model.newAnimation() }
                    .buttonStyle(SettingsButtonStyle(outlined: true))
                    .help("Starts as the animation in use and opens the Animation Studio")
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
            Group {
                if let animation = entry.animation {
                    MotionSparkline(motion: animation.open)
                } else {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .frame(width: 64, height: 30)
            .accessibilityHidden(true)
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

    // MARK: Examples

    private var examples: some View {
        SettingsCard("Examples", footer: "Add one to make a copy in your animations, ready to use or to change in the Animation Studio.") {
            ForEach(DropyAnimation.gallery, id: \.id) { example in
                HStack(spacing: SettingsMetrics.rowInset) {
                    MotionSparkline(motion: example.animation.open)
                        .frame(width: 64, height: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(example.animation.name).font(SettingsMetrics.body)
                        Text(example.animation.summary).font(SettingsMetrics.detail).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: SettingsMetrics.rowInset)
                    Button { _ = model.playOnNotch?(example.animation, 1) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(SettingsButtonStyle(circular: true))
                        .help("Play \(example.animation.name) on the notch")
                        .accessibilityLabel("Play \(example.animation.name) on the notch")
                    Button("Add") { model.addExample(example.id) }
                        .buttonStyle(SettingsButtonStyle())
                        .accessibilityLabel("Add \(example.animation.name)")
                }
                .settingsRow()
            }
        }
    }

    // MARK: AI

    private var ai: some View {
        SettingsCard {
          DisclosureGroup {
            SettingsRow("Copy a Prompt", detail: "Paste into a coding agent and describe the feel you want. The prompt includes the animation guide.") {
                Button(model.promptCopied ? "Copied" : "Copy Prompt") { model.copyAIPrompt() }
                    .buttonStyle(SettingsButtonStyle(outlined: true))
            }
            SettingsRow("Command Line", detail: "Check, draw, play and share animations from a terminal: \(AnimationLibrary.command) help") {
                Button("Copy") { model.copyAnimationCommand() }
                    .buttonStyle(SettingsButtonStyle())
            }
          } label: {
              SettingsLabel("Create with AI or a Terminal", detail: "A few more ways to make something personal.")
          }
          .padding(SettingsMetrics.rowInset)
        }
    }
}
