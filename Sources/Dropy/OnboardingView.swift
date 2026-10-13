import AppKit
import SwiftUI
import DropyCore

@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var step: OnboardingStep
    @Published var requestedScreenAccess = false
    let progress: OnboardingProgress
    let settings: SettingsModel
    var onFinish: ((Bool) -> Void)?
    var onPreview: (() -> Void)?

    init(progress: OnboardingProgress, settings: SettingsModel) {
        self.progress = progress
        self.settings = settings
        step = progress.isComplete ? .welcome : progress.step
    }

    func begin() {
        step = progress.isComplete ? .welcome : progress.step
        settings.refresh()
    }

    func move(_ delta: Int) {
        settings.stopRecordingShortcut()
        guard let next = OnboardingStep(rawValue: step.rawValue + delta) else { return }
        step = next
        if !progress.isComplete { progress.save(next) }
    }

    func finish(skipped: Bool = false) {
        settings.stopRecordingShortcut()
        progress.complete()
        onFinish?(skipped)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: SettingsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 60).accessibilityHidden(true)

            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases) { step in
                    HStack(spacing: 7) {
                        Image(systemName: step.rawValue < model.step.rawValue ? "checkmark.circle.fill" : "circle.fill")
                            .font(.system(size: 9))
                        Text(step.title).font(.system(size: 11, weight: step == model.step ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(step == model.step ? SettingsTheme.accent : Color.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(step == model.step ? SettingsTheme.selection : SettingsTheme.control.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel("Step \(step.rawValue + 1) of 4: \(step.title)")
                    .accessibilityAddTraits(step == model.step ? .isSelected : [])
                }
            }
            .padding(.horizontal, 28)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    page
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(model.step)
            .frame(maxHeight: .infinity)

            Rectangle().fill(SettingsTheme.separator).frame(height: 1)
            HStack(spacing: 12) {
                if model.step != .welcome {
                    Button("Back") { model.move(-1) }.buttonStyle(SettingsButtonStyle())
                }
                Button("Set Up Later") { model.finish(skipped: true) }
                    .buttonStyle(.plain).font(SettingsMetrics.detail).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.step.rawValue + 1) / 4").font(SettingsMetrics.detail.monospacedDigit()).foregroundStyle(.secondary)
                Button(model.step == .tryIt ? "Get Started" : "Continue") {
                    if model.step == .tryIt { model.finish() } else { model.move(1) }
                }
                .buttonStyle(SettingsButtonStyle(outlined: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
        }
        .background(SettingsTheme.background)
        .tint(SettingsTheme.accent)
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder private var page: some View {
        switch model.step {
        case .welcome:
            heading("Set Up Dropy", detail: "A temporary home for the app you need, right at the edge of your screen.")
            WorkspaceIllustration().frame(height: 190)
            HStack(alignment: .top, spacing: 24) {
                feature("Open", symbol: "macwindow.badge.plus", detail: "Bring an open app into Dropy.")
                feature("Use", symbol: "cursorarrow", detail: "Work in its familiar window.")
                feature("Return", symbol: "arrow.uturn.backward", detail: "Close Dropy and keep your session.")
            }
        case .permissions:
            heading("Permissions", detail: "macOS asks you to allow these in System Settings. You can continue now and grant access later.")
            SettingsCard {
                permission("Accessibility", symbol: "hand.point.up.left", detail: "Moves an app’s real window into Dropy so you can type, click and work as usual.", granted: settings.accessibilityGranted) {
                    settings.openAccessibilitySettings()
                }
                permission("Screen Recording", symbol: "rectangle.dashed.badge.record", detail: "Finds open windows and shows live previews when needed. Dropy saves no recording.", granted: settings.screenRecordingGranted) {
                    model.requestedScreenAccess = true
                    settings.openScreenRecordingSettings()
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield").foregroundStyle(SettingsTheme.accent)
                Text("Permission stays in your control. You can revoke it at any time in macOS System Settings.")
                    .font(SettingsMetrics.detail).foregroundStyle(.secondary)
            }
            if model.requestedScreenAccess && !settings.screenRecordingGranted {
                SettingsCard {
                    SettingsRow("Relaunch Required", detail: "If you’ve allowed Screen Recording, relaunch Dropy. Your setup progress is saved.") {
                        Button("Relaunch Dropy") { settings.relaunch() }.buttonStyle(SettingsButtonStyle())
                    }
                }
            }
        case .shortcut:
            heading("Keyboard Shortcut", detail: "Open and close Dropy from anywhere. Keep this shortcut or click it to make it yours.")
            VStack(spacing: 18) {
                Image(systemName: "keyboard").font(.system(size: 42, weight: .light)).foregroundStyle(SettingsTheme.accent)
                ShortcutButton(shortcut: settings.preferences.shortcut, isRecording: settings.isRecordingShortcut,
                               registered: settings.shortcutRegistered,
                               action: settings.isRecordingShortcut ? settings.stopRecordingShortcut : settings.recordShortcut)
                Text(settings.isRecordingShortcut ? "Press a shortcut with ⌘, ⌃ or ⌥. Esc cancels."
                     : "Press \(settings.preferences.shortcut.display) to open. Press it again to close.")
                    .font(SettingsMetrics.body).foregroundStyle(.secondary)
            }
            .padding(30).frame(maxWidth: .infinity)
            .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: 16))
            if let problem = settings.shortcutProblem {
                SettingsFootnote(problem, isError: true)
            } else if !settings.shortcutRegistered {
                SettingsFootnote("Another app already uses this shortcut. Click it above to choose a different one.", isError: true)
            }
            Text(Trigger.notchPaused ? "Opening by hover or click is currently paused. Your shortcut and the ◆ menu-bar button are available."
                 : "You can also open Dropy from the notch or the ◆ menu-bar button.")
                .font(SettingsMetrics.detail).foregroundStyle(.secondary)
        case .tryIt:
            heading("Overlay Preview", detail: "Watch Dropy open, make room, and tuck itself away. This demo uses sample content and needs no permissions.")
            if reduceMotion {
                WorkspaceIllustration().frame(height: 180)
                Text("Reduce Motion is on. The preview stays still; the optional demo plays the selected animation.")
                    .font(SettingsMetrics.detail).foregroundStyle(.secondary)
            } else {
                AnimationStage(animation: settings.animationChoice.animation, request: 0, parts: [.open, .resize, .close, .open])
                    .frame(height: 180)
            }
            HStack {
                Button("Play on My Screen") { model.onPreview?() }.buttonStyle(SettingsButtonStyle(outlined: true))
                Spacer()
                Text(settings.animationChoice.animation.name).font(SettingsMetrics.body).foregroundStyle(.secondary)
            }
            Text("Get Started opens Settings to configure a pinned app, overlay size and position, and animation.")
                .font(SettingsMetrics.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 29, weight: .bold, design: .rounded)).tracking(-0.6)
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feature(_ title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(SettingsTheme.accent)
            Text(title).font(SettingsMetrics.bodyEmphasis)
            Text(detail).font(SettingsMetrics.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permission(_ title: String, symbol: String, detail: String, granted: Bool,
                            action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(SettingsTheme.accent)
                .frame(width: 36).accessibilityHidden(true)
            SettingsLabel(title, detail: detail)
            Spacer(minLength: 10)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(SettingsMetrics.bodyEmphasis).foregroundStyle(.green)
            } else {
                Button("Allow Access", action: action).buttonStyle(SettingsButtonStyle(outlined: true))
                    .accessibilityLabel("Allow \(title)")
            }
        }.settingsRow()
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    private var window: NSWindow?
    var onVisibilityChange: (() -> Void)?
    var onClose: (() -> Void)?
    var isVisible: Bool { window?.isVisible ?? false }

    init(model: OnboardingModel) { self.model = model }

    func show() {
        model.begin()
        let window = self.window ?? makeWindow()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        onVisibilityChange?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: OnboardingView(model: model, settings: model.settings))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = "Dropy Setup"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 720, height: 640))
        window.delegate = self
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) { model.settings.refresh() }
    func windowDidResignKey(_ notification: Notification) { model.settings.stopRecordingShortcut() }
    func windowWillClose(_ notification: Notification) {
        model.settings.stopRecordingShortcut()
        onClose?()
        DispatchQueue.main.async { [weak self] in self?.onVisibilityChange?() }
    }
}
