import AppKit
import SwiftUI
import DropyCore

@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var step: OnboardingStep
    @Published var requestedScreenAccess = false
    /// +1 moving forward, -1 back; pages slide in from that side.
    @Published private(set) var direction = 1
    /// Set while Get Started plays its launch; guards against finishing twice.
    @Published var celebration: Date?
    /// Welcome's notch has been opened this session; going back shows it open.
    @Published var welcomeOpened = false
    /// How many times the real shortcut was pressed on the Shortcut step.
    @Published private(set) var shortcutPresses = 0
    let progress: OnboardingProgress
    let settings: SettingsModel
    var onFinish: ((Bool) -> Void)?
    var onPreview: (() -> Void)?
    /// Plays the launch burst across the screen.
    var onCelebrate: (() -> Void)?

    init(progress: OnboardingProgress, settings: SettingsModel) {
        self.progress = progress
        self.settings = settings
        step = progress.isComplete ? .welcome : progress.step
    }

    func begin() {
        celebration = nil
        welcomeOpened = false
        shortcutPresses = 0
        step = progress.isComplete ? .welcome : progress.step
        settings.refresh()
    }

    func move(_ delta: Int) {
        settings.stopRecordingShortcut()
        guard let next = OnboardingStep(rawValue: step.rawValue + delta) else { return }
        direction = delta < 0 ? -1 : 1
        step = next
        if !progress.isComplete { progress.save(next) }
    }

    /// The global shortcut, pressed while the Shortcut step is showing: play the real
    /// animation on the notch instead of opening the overlay.
    func shortcutPressed() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { shortcutPresses += 1 }
        onPreview?()
    }

    func finish(skipped: Bool = false) {
        settings.stopRecordingShortcut()
        celebration = nil
        progress.complete()
        onFinish?(skipped)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: SettingsModel
    @Namespace private var rail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            OnboardingBackdrop()

            VStack(spacing: 0) {
                stepRail.padding(.horizontal, 28).padding(.top, 18)
                // Pages are laid out to fit; nothing here scrolls.
                ZStack {
                    VStack(spacing: 22) { page }
                        .padding(.horizontal, 36).padding(.vertical, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(model.step)
                        .transition(.onboardingPage(direction: model.direction, reduceMotion: reduceMotion))
                }
                .frame(maxHeight: .infinity)
                .clipped()
                footer
            }
        }
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea(.container, edges: .top)
    }

    /// The steps on one glass track; a lit pill slides to the current one.
    private var stepRail: some View {
        HStack(spacing: 4) {
            ForEach(OnboardingStep.allCases) { step in
                let current = step == model.step
                let done = step.rawValue < model.step.rawValue
                Button {
                    go(to: step)
                } label: {
                    HStack(spacing: 7) {
                        ZStack {
                            if done {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                                    .transition(.scale(scale: 0.2).combined(with: .opacity))
                            } else {
                                Text("\(step.rawValue + 1)").font(.system(size: 10, weight: .bold, design: .rounded))
                                    .transition(.scale(scale: 0.2).combined(with: .opacity))
                            }
                        }
                        .frame(width: 18, height: 18)
                        .background(current ? Color.black.opacity(0.12) : done ? Color.white.opacity(0.14) : Color.white.opacity(0.05),
                                    in: Circle())
                        Text(step.title).font(.system(size: 12, weight: current ? .semibold : .medium))
                    }
                    .foregroundStyle(current ? Color.black : done ? Color(white: 0.85) : Color(white: 0.52))
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .background {
                        if current {
                            Capsule().fill(OnboardingStyle.metal)
                                .shadow(color: .white.opacity(0.18), radius: 10)
                                .matchedGeometryEffect(id: "pill", in: rail)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .allowsHitTesting(step.rawValue <= model.step.rawValue)
                .accessibilityLabel("Step \(step.rawValue + 1) of 4: \(step.title)")
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .padding(4)
        .onboardingSurface(Capsule())
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.step != .welcome {
                Button { go(-1) } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(OnboardingGlassStyle())
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
            Button("Set Up Later") { model.finish(skipped: true) }
                .buttonStyle(.plain).font(SettingsMetrics.detail).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 0) {
                Text("\(model.step.rawValue + 1)").contentTransition(.numericText(countsDown: model.direction < 0))
                Text(" / 4")
            }
            .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.secondary)
            Button {
                if model.step == .tryIt { celebrate() } else { go(1) }
            } label: {
                HStack(spacing: 6) {
                    Text(model.step == .tryIt ? "Get Started" : "Continue")
                        .contentTransition(.interpolate)
                    Image(systemName: model.step == .tryIt ? "sparkles" : "arrow.right")
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(OnboardingPrimaryStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(model.celebration != nil)
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .background(alignment: .top) {
            LinearGradient(colors: [.white.opacity(0.0), .white.opacity(0.12), .white.opacity(0.0)],
                           startPoint: .leading, endPoint: .trailing).frame(height: 1)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.step {
        case .welcome: welcomePage
        case .permissions: permissionsPage
        case .shortcut: shortcutPage
        case .tryIt: tryItPage
        }
    }

    private var welcomePage: some View {
        // Hangs from the top of the page, which reads as the top edge of a screen.
        WelcomeIntro(model: model).padding(.top, -16).padding(.bottom, -4)
    }

    @ViewBuilder private var permissionsPage: some View {
        let allowed = settings.accessibilityGranted && settings.screenRecordingGranted
        ShieldHero(allowed: allowed).rise(0)
        OnboardingHeading(title: "Permissions",
                          detail: "macOS asks you to allow these in System Settings. You can continue now and grant access later.")
        VStack(spacing: 12) {
            permission("Accessibility", symbol: "hand.point.up.left.fill",
                                              detail: "Moves an app’s real window into Dropy so you can type, click and work as usual.",
                       granted: settings.accessibilityGranted) {
                settings.openAccessibilitySettings()
            }
            .rise(4)
            permission("Screen Recording", symbol: "rectangle.dashed.badge.record",
                                              detail: "Finds open windows and shows live previews when needed. Dropy saves no recording.",
                       granted: settings.screenRecordingGranted) {
                model.requestedScreenAccess = true
                settings.openScreenRecordingSettings()
            }
            .rise(5)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: settings.accessibilityGranted)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: settings.screenRecordingGranted)
        if model.requestedScreenAccess && !settings.screenRecordingGranted {
            HStack(spacing: 14) {
                Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 22))
                    .foregroundStyle(Color(white: 0.85))
                    .symbolEffect(.rotate, options: .repeat(.periodic(delay: 2)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Relaunch Required").font(SettingsMetrics.bodyEmphasis)
                    Text("If you’ve allowed Screen Recording, relaunch Dropy. Your setup progress is saved.")
                        .font(SettingsMetrics.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Button("Relaunch Dropy") { settings.relaunch() }.buttonStyle(OnboardingGlassStyle())
            }
            .padding(16)
            .onboardingSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        Label("Permission stays in your control. You can revoke it at any time in macOS System Settings.",
              systemImage: "lock.fill")
            .font(SettingsMetrics.detail).foregroundStyle(.secondary)
            .rise(6)
    }

    @ViewBuilder private var shortcutPage: some View {
        Button {
            if settings.isRecordingShortcut { settings.stopRecordingShortcut() } else { settings.recordShortcut() }
        } label: {
            KeycapHero(keys: settings.preferences.shortcut.keycaps, isRecording: settings.isRecordingShortcut)
                .opacity(settings.shortcutRegistered || settings.isRecordingShortcut ? 1 : 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
        .help(settings.isRecordingShortcut ? "Press the new shortcut. Esc cancels." : "Click to record a new shortcut")
        .accessibilityLabel("Open Dropy shortcut")
        .accessibilityValue(settings.isRecordingShortcut ? "Recording" : settings.preferences.shortcut.display)
        .accessibilityHint(settings.isRecordingShortcut ? "Press the new shortcut, or Esc to cancel." : "Records a new shortcut.")
        .rise(0)
        OnboardingHeading(title: "Keyboard Shortcut",
                          detail: "Open and close Dropy from anywhere. Press it now to see Dropy open at the top of your screen, or click the keys to choose another.")
        shortcutPrompt.rise(4)
        if let problem = settings.shortcutProblem {
            SettingsFootnote(problem, isError: true).transition(.opacity)
        } else if !settings.shortcutRegistered {
            SettingsFootnote("Another app already uses this shortcut. Click it above to choose a different one.", isError: true)
                .transition(.opacity)
        }
        Label(Trigger.notchPaused ? String("Opening by hover or click is currently paused. Your shortcut and the ◆ menu-bar button are available.")
              : String("You can also open Dropy from the notch or the ◆ menu-bar button."),
              systemImage: "menubar.rectangle")
            .font(SettingsMetrics.detail).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .rise(5)
    }

    @ViewBuilder private var tryItPage: some View {
        OnboardingHeading(title: "Overlay Preview",
                          detail: "Watch Dropy open, make room, and tuck itself away. This demo uses sample content and needs no permissions.")
        notchPreview(height: 220).hoverLift().rise(3)
        if reduceMotion {
            Text("Reduce Motion is on. The preview stays still; the optional demo plays the selected animation.")
                .font(SettingsMetrics.detail).foregroundStyle(.secondary)
        }
        HStack(spacing: 12) {
            Button { model.onPreview?() } label: { Label("Play on My Screen", systemImage: "play.fill") }
                .buttonStyle(OnboardingGlassStyle())
            Label(settings.animationChoice.animation.name, systemImage: "wand.and.stars")
                .font(SettingsMetrics.body).foregroundStyle(.secondary)
        }
        .rise(4)
        Text("Get Started opens Settings to configure a pinned app, overlay size and position, and animation.")
            .font(SettingsMetrics.body).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 520)
            .rise(5)
    }

    /// The production notch animation on sample content, looping.
    private func notchPreview(height: CGFloat) -> some View {
        Group {
            if reduceMotion {
                WorkspaceIllustration()
            } else {
                AnimationStage(animation: settings.animationChoice.animation, request: 0,
                               parts: [.open, .resize, .close, .open], loop: true)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 1)
        }
    }

    /// Asks for the real shortcut, then confirms once it has been pressed.
    @ViewBuilder private var shortcutPrompt: some View {
        let pressed = model.shortcutPresses > 0
        HStack(spacing: 10) {
            if settings.isRecordingShortcut {
                Text("Press a shortcut with ⌘, ⌃ or ⌥. Esc cancels.")
            } else if pressed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .symbolEffect(.bounce, value: model.shortcutPresses)
                Text("That’s it. Press \(settings.preferences.shortcut.display) anywhere to open Dropy.")
            } else {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                Text("Try it now: press \(settings.preferences.shortcut.display)")
            }
        }
        .font(.system(size: 13.5, weight: .medium))
        .padding(.horizontal, 18).frame(height: 38)
        .onboardingSurface(Capsule())
        .overlay { Capsule().strokeBorder(Color.green.opacity(pressed && !settings.isRecordingShortcut ? 0.4 : 0), lineWidth: 1) }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: pressed)
        .animation(.easeInOut(duration: 0.25), value: settings.isRecordingShortcut)
    }

    private func go(_ delta: Int) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : OnboardingStyle.pageSpring) { model.move(delta) }
    }

    private func go(to step: OnboardingStep) {
        let delta = step.rawValue - model.step.rawValue
        if delta != 0 { go(delta) }
    }

    /// The window steps aside and the real notch drops down with the shortcut; Settings
    /// opens as it tucks back.
    private func celebrate() {
        guard model.celebration == nil else { return }
        model.celebration = Date()
        guard let launch = model.onCelebrate else { return model.finish() }
        launch()
    }

    private func permission(_ title: String, symbol: String, detail: String, granted: Bool,
                            action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [OnboardingStyle.raised, OnboardingStyle.ink], startPoint: .top, endPoint: .bottom))
                .overlay { Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(Color(white: 0.9)) }
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1) }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(SettingsMetrics.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            ZStack {
                if granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .font(SettingsMetrics.bodyEmphasis).foregroundStyle(.green)
                        .symbolEffect(.bounce, value: granted)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Button("Allow Access", action: action)
                        .buttonStyle(OnboardingPrimaryStyle(compact: true))
                        .accessibilityLabel("Allow \(title)")
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
        }
        .padding(16)
        .onboardingSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.green.opacity(granted ? 0.4 : 0), lineWidth: 1)
                .shadow(color: .green.opacity(granted ? 0.25 : 0), radius: 8)
        }
        .hoverLift()
    }
}

/// Welcome's opening: the title and a Get to Know More button. Clicking it pulls both
/// into a notch at the page's top edge, and the notch opens like Dropy does to show what
/// it is for.
private struct WelcomeIntro: View {
    @ObservedObject var model: OnboardingModel
    @StateObject private var intro = IntroState()
    @Namespace private var morph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let phase = model.welcomeOpened && intro.phase == 0 ? 2 : intro.phase
            let expanded = phase >= 2
            ZStack(alignment: .top) {
                // The screen's top edge the notch hangs from.
                LinearGradient(colors: [.clear, .white.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
                if phase == 0 {
                    VStack(spacing: 26) {
                        Text("Set Up Dropy")
                            .font(.system(size: 44, weight: .semibold)).tracking(-1.4)
                            .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.62)], startPoint: .top, endPoint: .bottom))
                            .textRenderer(GlyphReveal(progress: intro.titleShown || reduceMotion ? 1 : 0))
                            .accessibilityAddTraits(.isHeader)
                        Button { open() } label: {
                            HStack(spacing: 6) {
                                Text("Get to Know More")
                                Image(systemName: "arrow.up")
                            }
                        }
                        .buttonStyle(OnboardingPrimaryStyle())
                        .rise(6)
                    }
                    .matchedGeometryEffect(id: "notch", in: morph)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.4)))
                } else {
                    NotchPanelShape(ear: 10, radius: expanded ? 28 : 12)
                        .fill(Color.black)
                        .overlay {
                            NotchPanelShape(ear: 10, radius: expanded ? 28 : 12)
                                .stroke(LinearGradient(colors: [.white.opacity(0.02), .white.opacity(expanded ? 0.14 : 0.05)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1)
                        }
                        .overlay {
                            if expanded {
                                WelcomePanelContent()
                                    .padding(.horizontal, 40).padding(.top, 22).padding(.bottom, 28)
                            }
                        }
                        .frame(width: expanded ? proxy.size.width - 16 : 168, height: expanded ? min(proxy.size.height - 40, 400) : 32)
                        .shadow(color: .black.opacity(expanded ? 0.55 : 0), radius: 30, y: 16)
                        .matchedGeometryEffect(id: "notch", in: morph)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.0).delay(0.1)) { intro.titleShown = true }
        }
    }

    private func open() {
        guard intro.phase == 0 else { return }
        if reduceMotion { intro.phase = 2; model.welcomeOpened = true; return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.84)) { intro.phase = 1 }
        Task { @MainActor [intro, model] in
            try? await Task.sleep(for: .seconds(0.55))
            withAnimation(.spring(response: 0.62, dampingFraction: 0.78)) { intro.phase = 2 }
            model.welcomeOpened = true
        }
    }
}

@MainActor
private final class IntroState: ObservableObject {
    @Published var phase = 0
    @Published var titleShown = false
}

private struct WelcomePanelContent: View {
    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Text("Set Up Dropy")
                    .font(.system(size: 30, weight: .semibold)).tracking(-0.9)
                    .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.65)], startPoint: .top, endPoint: .bottom))
                    .rise(0)
                Text("A temporary home for the app you need, right at the edge of your screen.")
                    .font(.system(size: 13.5)).foregroundStyle(Color(white: 0.56))
                    .multilineTextAlignment(.center)
                    .rise(1)
            }
            HStack(alignment: .top, spacing: 14) {
                FeatureCard(title: "Open", symbol: "macwindow.badge.plus", detail: "Bring an open app into Dropy.").rise(3)
                FeatureCard(title: "Use", symbol: "cursorarrow.rays", detail: "Work in its familiar window.").rise(4)
                FeatureCard(title: "Return", symbol: "arrow.uturn.backward", detail: "Close Dropy and keep your session.").rise(5)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A welcome feature on glass; its symbol hops when hovered.
private struct FeatureCard: View {
    let title: String
    let symbol: String
    let detail: String
    @StateObject private var hover = HoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(white: hover.isHovered ? 1 : 0.85))
                .frame(width: 36, height: 36)
                .background(LinearGradient(colors: [OnboardingStyle.raised, OnboardingStyle.ink], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(hover.isHovered ? 0.3 : 0.14), lineWidth: 1) }
                .symbolEffect(.bounce, value: hover.isHovered)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(SettingsMetrics.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .hoverLift()
        .onHover { hover.isHovered = $0 }
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    private var window: NSWindow?
    var onVisibilityChange: (() -> Void)?
    var onClose: (() -> Void)?
    var isVisible: Bool { window?.isVisible ?? false }

    init(model: OnboardingModel) {
        self.model = model
        super.init()
        model.onCelebrate = { [weak self] in self?.launch() }
    }

    func show() {
        model.begin()
        let window = self.window ?? makeWindow()
        self.window = window
        window.alphaValue = 1
        window.center()
        window.makeKeyAndOrderFront(nil)
        onVisibilityChange?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    /// Fades the window out, drops the notch with the shortcut, and finishes as it tucks back.
    private func launch() {
        guard let window else { return model.finish() }
        let keys = model.settings.preferences.shortcut.keycaps
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                window.orderOut(nil)
                NotchHint.play(keys: keys) { self?.model.finish() }
            }
        })
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: OnboardingView(model: model, settings: model.settings))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = "Dropy Setup"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Titled for its rounded corners and key focus, but setup has no window controls:
        // Set Up Later and Get Started are the ways out.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.animationBehavior = .alertPanel
        window.setContentSize(CGSize(width: 760, height: 720))
        window.delegate = self
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) { model.settings.refresh() }
    func windowDidResignKey(_ notification: Notification) { model.settings.stopRecordingShortcut() }
    func windowWillClose(_ notification: Notification) {
        model.celebration = nil
        model.settings.stopRecordingShortcut()
        onClose?()
        DispatchQueue.main.async { [weak self] in self?.onVisibilityChange?() }
    }
}
