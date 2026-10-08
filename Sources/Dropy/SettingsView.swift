import AppKit
import ServiceManagement
import SwiftUI
import DropyCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, opening, overlay, animation, interaction, permissions, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .opening: "Opening"
        case .overlay: "Overlay"
        case .animation: "Animation"
        case .interaction: "Interaction"
        case .permissions: "Permissions"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .opening: "macwindow.badge.plus"
        case .overlay: "rectangle.center.inset.filled"
        case .animation: "wand.and.stars"
        case .interaction: "hand.point.up.left.fill"
        case .permissions: "lock.shield.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        case .about: "info.circle.fill"
        }
    }

    /// Shown beside the page name in the sidebar.
    var badge: String? { nil }
}

private struct SettingsTopic: Identifiable {
    let id: String
    let pane: SettingsPane
    let title: String
    let detail: String
    let keywords: String

    static let all: [SettingsTopic] = [
        SettingsTopic(id: "login", pane: .general, title: "Open at Login",
                      detail: "Start Dropy when you log in.",
                      keywords: "login items startup launch"),
        SettingsTopic(id: "dock", pane: .general, title: "Show in Dock",
                      detail: "A Dock icon and Dropy's own menu bar.",
                      keywords: "menu bar diamond icon dock"),
        SettingsTopic(id: "shortcut", pane: .general, title: "Dropy Hotkey",
                      detail: "Opens and closes the overlay from anywhere.",
                      keywords: "hotkey shortcut keys option space"),
        SettingsTopic(id: "about", pane: .about, title: "About Dropy",
                      detail: "Version, the project page, and this copy in Finder.",
                      keywords: "version mit license finder applications install"),
        SettingsTopic(id: "pin", pane: .opening, title: "Pinned App",
                      detail: "The app every opening shows, launched if it is not running.",
                      keywords: "pin pinned choose application favorite"),
        SettingsTopic(id: "trigger", pane: .opening, title: "Open from the Notch",
                      detail: "Hover, click, or the shortcut only. Notch opening is paused.",
                      keywords: "hover click notch trigger"),
        SettingsTopic(id: "behavior", pane: .opening, title: "Show on Opening",
                      detail: "The window picker, the saved app, or the last used app.",
                      keywords: "picker direct last used window"),
        SettingsTopic(id: "dismiss", pane: .opening, title: "Close the Overlay",
                      detail: "Esc and Close, a click outside, or the pointer leaving.",
                      keywords: "dismiss close escape click outside pointer leave"),
        SettingsTopic(id: "size", pane: .overlay, title: "Overlay Size",
                      detail: "Compact, Medium, Wide, or the window's own size.",
                      keywords: "compact medium wide true native size dimensions expand"),
        SettingsTopic(id: "fit", pane: .overlay, title: "Adapt to the Window",
                      detail: "Small windows keep their size. Larger ones scale down.",
                      keywords: "automatic scale native shrink"),
        SettingsTopic(id: "motion", pane: .animation, title: "Animation Style",
                      detail: "Rapid, Balanced, Smooth, or one of your own.",
                      keywords: "animation motion speed fast rapid smooth balanced spring bounce"),
        SettingsTopic(id: "studio", pane: .animation, title: "Animation Studio",
                      detail: "Make your own: springs, keyframes, or draw the curve.",
                      keywords: "custom animation builder editor keyframes timeline frames draw curve spring easing"),
        SettingsTopic(id: "aiAnimation", pane: .animation, title: "Make an Animation with AI",
                      detail: "A prompt for Claude Code, Codex or Cursor.",
                      keywords: "ai agent claude codex cursor prompt command line terminal"),
        SettingsTopic(id: "shareAnimation", pane: .animation, title: "Share an Animation",
                      detail: "Copy a share code, or paste one.",
                      keywords: "share code import export paste copy gallery examples"),
        SettingsTopic(id: "content", pane: .overlay, title: "Content Scaling",
                      detail: "Fit, Fill, or native size.",
                      keywords: "fit fill crop scale letterbox"),
        SettingsTopic(id: "interactive", pane: .interaction, title: "Use the App",
                      detail: "The real app in the overlay, or a live preview only.",
                      keywords: "full app interactive click scroll typing keyboard shortcuts preview window"),
        SettingsTopic(id: "ready", pane: .interaction, title: "Keep Pinned App Ready",
                      detail: "The pinned app waits on a hidden display and opens on any desktop.",
                      keywords: "stage hidden display virtual desktop spaces full screen instant"),
        SettingsTopic(id: "crossing", pane: .interaction, title: "Keep the Pointer Beside the Notch",
                      detail: "Experimental hold on sideways movement across the notch.",
                      keywords: "cursor pointer experimental accessibility option"),
        SettingsTopic(id: "screen", pane: .permissions, title: "Screen Recording",
                      detail: "Shows the window you pick. A new grant needs a relaunch.",
                      keywords: "permission privacy capture screen recording"),
        SettingsTopic(id: "access", pane: .permissions, title: "Accessibility",
                      detail: "Brings the app's real window into the overlay.",
                      keywords: "permission privacy accessibility"),
        SettingsTopic(id: "reset", pane: .advanced, title: "Reset All Settings",
                      detail: "Restores the defaults. Open at login is left as it is.",
                      keywords: "reset defaults restore"),
        SettingsTopic(id: "support", pane: .advanced, title: "Support Summary",
                      detail: "Copies version, permissions and choices. No window titles.",
                      keywords: "copy clipboard diagnostics support"),
    ]
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private var trimmedQuery: String { model.settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var matches: [SettingsTopic] {
        let q = trimmedQuery
        guard !q.isEmpty else { return [] }
        return SettingsTopic.all.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.detail.localizedCaseInsensitiveContains(q)
                || $0.keywords.localizedCaseInsensitiveContains(q)
                || $0.pane.title.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: model.sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(SettingsSidebarGlass())
                // Drawn over the glass's edge rather than as its own column: the window
                // is transparent there, so a separate column showed the desktop.
                .overlay(alignment: .trailing) { SettingsSidebarDivider(model: model) }
                .zIndex(1)

            VStack(alignment: .leading, spacing: 0) {
                SettingsHistoryButtons(model: model)
                    .padding(.leading, SettingsMetrics.pageInset)
                    .frame(height: SettingsMetrics.titleBarHeight)
                Group {
                    if trimmedQuery.isEmpty {
                        paneBody.id(model.pane)
                    } else {
                        searchResults
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(SettingsTheme.background)
        }
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.settingsQuery) { _, query in
            if !query.isEmpty { model.stopRecordingShortcut() }
        }
        .sheet(isPresented: Binding(get: { model.isChoosingApp }, set: { model.isChoosingApp = $0 })) {
            AppChooserSheet(model: model)
        }
    }

    @ViewBuilder private var paneBody: some View {
        switch model.pane {
        case .general: general
        case .opening: opening
        case .overlay: overlay
        case .animation: AnimationSettingsPage(model: model)
        case .interaction: interaction
        case .permissions: permissions
        case .advanced: advanced
        case .about: about
        }
    }

    private var searchResults: some View {
        Group {
            if matches.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                SettingsPage {
                    ForEach(SettingsPane.allCases) { resultPane in
                        let topics = matches.filter { $0.pane == resultPane }
                        if !topics.isEmpty {
                            SettingsCard(resultPane.title) {
                                ForEach(topics) { topic in
                                    Button {
                                        model.navigate(to: topic.pane)
                                    } label: {
                                        HStack(spacing: SettingsMetrics.rowInset) {
                                            SettingsIcon(symbol: topic.pane.symbol)
                                            SettingsLabel(topic.title, detail: topic.detail)
                                            Spacer(minLength: 12)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                        }
                                        .settingsRow()
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: General

    private var general: some View {
        SettingsPage {
            SettingsCard(footer: "Dropy is always available in the menu bar. While Settings is open, it also appears in the Dock.") {
                SettingsToggleRow("Open at Login", isOn: model.opensAtLogin)
                loginStatus
                if !model.isInstalled {
                    SettingsNotice(symbol: "app.badge", title: "Running a development copy",
                                   detail: "Move Dropy to Applications before enabling Open at Login.")
                }
                SettingsToggleRow("Show in Dock", isOn: model.binding(\.showInDock))
                shortcutRow
            }
        }
    }

    @ViewBuilder private var loginStatus: some View {
        if model.loginItemStatus == .requiresApproval {
            SettingsRow("Finish in Login Items", detail: "Allow Dropy in Login Items to finish.") {
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(SettingsButtonStyle())
            }
        } else if model.loginItemStatus == .notFound {
            SettingsNotice(symbol: "exclamationmark.triangle", title: "Registered copy missing",
                           detail: "Turn this off and on from the app in Applications.")
        }
        if let error = model.loginItemError {
            SettingsNotice(symbol: "exclamationmark.triangle", title: "Couldn’t change Open at Login", detail: error)
        }
    }

    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Dropy Hotkey") {
                if model.isRecordingShortcut {
                    Button("Cancel", action: model.stopRecordingShortcut)
                        .buttonStyle(SettingsButtonStyle())
                }
                ShortcutButton(shortcut: model.preferences.shortcut,
                               isRecording: model.isRecordingShortcut,
                               registered: model.shortcutRegistered,
                               action: model.isRecordingShortcut ? model.stopRecordingShortcut : model.recordShortcut)
                Button(action: model.resetShortcut) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(SettingsButtonStyle(circular: true))
                .disabled(model.preferences.shortcut == .default)
                .help("Reset to \(KeyShortcut.default.display)")
                .accessibilityLabel("Reset shortcut")
            }
            if let problem = model.shortcutProblem {
                shortcutMessage(problem)
            } else if !model.shortcutRegistered {
                shortcutMessage("Another app uses \(model.preferences.shortcut.display), so it does nothing. Choose a different one.")
            }
        }
    }

    private func shortcutMessage(_ text: String) -> some View {
        SettingsFootnote(text, isError: true)
            .padding(.horizontal, SettingsMetrics.rowInset).padding(.bottom, SettingsMetrics.rowVerticalPadding)
    }

    // MARK: Opening

    private var opening: some View {
        SettingsPage {
            SettingsCard(footer: "A pinned app opens every time. Dropy launches it for you when needed.") {
                pinnedRow
            }

            SettingsCard("Window Selection", footer: openDetail) {
                SettingsRow("Show on Opening") {
                    SettingsMenu(label: "Show on opening", selection: model.binding(\.openBehavior), options: [
                        ("Window picker", .picker), ("Saved app", .direct), ("Last used app", .lastUsed),
                    ])
                    .disabled(model.preferences.pinnedBundleIdentifier != nil)
                }
                if model.preferences.openBehavior == .direct {
                    SettingsRow("Saved App") {
                        SettingsValue(model.preferences.selectedBundleIdentifier.map(model.appName) ?? "Choose a window to save an app")
                    }
                } else if model.preferences.openBehavior == .lastUsed {
                    SettingsRow("Last Used App") {
                        SettingsValue(model.preferences.lastUsedBundleIdentifier.map(model.appName) ?? "None yet")
                    }
                }
            }

            SettingsCard("Closing", footer: dismissDetail) {
                SettingsRow("Close the Overlay") {
                    SettingsMenu(label: "Close the overlay", selection: model.binding(\.dismissBehavior), options: [
                        ("Manually", .manual), ("On click outside", .clickOutside), ("When the pointer leaves", .pointerLeave),
                    ])
                }
            }

            SettingsCard("Notch") {
                SettingsRow("Open from the Notch") {
                    SettingsMenu(label: "Open from the notch", selection: model.binding(\.trigger), options: [
                        ("On hover", .notchHover), ("On click", .notchClick), ("Shortcut only", .shortcut),
                    ])
                    .disabled(Trigger.notchPaused)
                }
                if Trigger.notchPaused {
                    SettingsNotice(symbol: "pause.circle", title: "Notch opening is temporarily unavailable",
                                   detail: "Use your keyboard shortcut. Your preference, “\(triggerName),” is saved.")
                }
            }
        }
    }

    private var pinnedRow: some View {
        HStack(spacing: SettingsMetrics.rowInset) {
            if let pinned = model.pinnedApp {
                if let icon = pinned.icon {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
                }
                SettingsLabel(pinned.name, detail: "Your go-to app, always within reach.")
                Spacer(minLength: 8)
                Button("Remove", action: model.unpin).buttonStyle(SettingsButtonStyle())
                Button("Change…", action: model.prepareAppList).buttonStyle(SettingsButtonStyle(outlined: true))
            } else {
                SettingsLabel("Pinned App", detail: "Open straight into an app you use often.")
                Spacer(minLength: 8)
                Button("Choose App…", action: model.prepareAppList).buttonStyle(SettingsButtonStyle(outlined: true))
            }
        }
        .settingsRow()
    }

    private var triggerName: String {
        switch model.preferences.trigger {
        case .notchHover: "On hover"
        case .notchClick: "On click"
        case .shortcut: "Shortcut only"
        }
    }

    private var openDetail: String {
        if model.preferences.pinnedBundleIdentifier != nil {
            return "A pinned app opens instead of this choice. The choice is kept for when you remove the pin."
        }
        switch model.preferences.openBehavior {
        case .picker: return "Every opening asks you to pick a window."
        case .direct: return "Opens the saved app. It is remembered when you pick one of its windows."
        case .lastUsed: return "Opens whichever app was shown last."
        }
    }

    private var dismissDetail: String {
        switch model.preferences.dismissBehavior {
        case .manual:
            "The shortcut and Esc close it. A click outside leaves it open. Switching to another app always closes it."
        case .clickOutside:
            "A click outside the overlay or the app in it closes it. The shortcut and Esc still work."
        case .pointerLeave:
            "The window list and the preview close after the pointer leaves them. An app in the overlay closes on a click outside."
        }
    }

    // MARK: Overlay

    private var overlay: some View {
        SettingsPage {
            SettingsCard {
                VStack(alignment: .leading, spacing: SettingsMetrics.rowInset) {
                    SettingsLabel("Overlay Size", detail: sizeDetail(model.preferences.sizePreset))
                    OverlaySizeTiles(selection: model.binding(\.sizePreset))
                }
                .padding(SettingsMetrics.rowInset)
                SettingsToggleRow("Adapt to the Window",
                                  detail: model.preferences.sizePreset == .nativeSize
                                      ? "Native size follows the original window, shrinking only to fit your screen."
                                      : "Keep smaller windows at their original size. Larger ones scale down.",
                                  isOn: model.binding(\.automaticWindowSize))
                    .disabled(model.preferences.sizePreset == .nativeSize)
            }

            SettingsCard("Appearance") {
                SettingsRow("Content Scaling", detail: contentDetail) {
                    SettingsChoiceTiles(label: "Content scaling", selection: model.binding(\.contentMode), options: [
                        ("Fit", .fit, "Fit entire window"),
                        ("Fill", .fill, "Fill overlay"),
                        ("1:1", .nativeScale, "Native scale"),
                    ])
                }
            }
        }
    }

    private func sizeDetail(_ preset: SizePreset) -> String {
        switch preset {
        case .nativeSize: return "Use the window’s original size, up to the available screen space."
        default:
            let size = preset.dimensions
            return "Up to \(Int(size.width)) × \(Int(size.height)) points. Expand the overlay whenever you need more room."
        }
    }


    private var contentDetail: String {
        switch model.preferences.contentMode {
        case .fit:
            "The whole window stays visible, with empty space when shapes differ."
        case .fill:
            "The overlay is filled. Edges of the window can sit outside the preview."
        case .nativeScale:
            "One point of the window is one point on screen, until it is larger than the overlay."
        case .selectedRegion:
            "A chosen region is not available."
        }
    }

    // MARK: Interaction

    private var interaction: some View {
        SettingsPage {
            SettingsCard(footer: interactionFooter) {
                SettingsRow("Use the App", detail: interactionDetail) {
                    SettingsChoiceTiles(label: "Use the app", selection: model.binding(\.interaction), options: [
                        ("Full App", .fullApp, "Use the real app in the overlay"),
                        ("Preview", .previewOnly, "Show a live preview only"),
                    ])
                }
                SettingsToggleRow("Keep Pinned App Ready",
                                  detail: "Its window waits on a hidden display between openings, so it opens on any desktop.",
                                  isOn: model.binding(\.keepsPinnedAppReady))
                    .disabled(model.preferences.interaction != .fullApp)
                if model.preferences.interaction == .fullApp, !model.accessibilityGranted {
                    SettingsNotice(symbol: "hand.raised", title: "Accessibility access required",
                                   detail: "Allow Dropy to move the app's window into the overlay. Until then it is a preview.") {
                        Button("Open Settings…", action: model.openAccessibilitySettings)
                            .buttonStyle(SettingsButtonStyle(outlined: true))
                    }
                }
            }

            SettingsCard("Notch Crossing", badge: "Experimental",
                         footer: "Requires Accessibility. Hold Option to cross, or move below the notch. This feature has not yet been verified on hardware.") {
                SettingsToggleRow("Keep the Pointer Beside the Notch",
                                  detail: "Restrict sideways movement while Dropy is closed.",
                                  isOn: model.binding(\.restrictNotchCrossing))
                if model.preferences.restrictNotchCrossing {
                    SettingsNotice(symbol: "info.circle", title: "Notch restriction", detail: crossingStatus)
                }
            }
        }
    }

    private var interactionDetail: String {
        switch model.preferences.interaction {
        case .fullApp: "Typing, shortcuts, menus and dragging work as they do anywhere else."
        case .previewOnly: "A live picture of the window. Clicks and keys are not sent to it."
        }
    }

    private var interactionFooter: String {
        "With Full App, the app's own window moves into the overlay and its app comes to the front. Over a full-screen app, Dropy streams the window instead, so macOS shows its screen-recording indicator while it is open. A window you pick that isn't pinned goes back where it was."
    }

    private var crossingStatus: String {
        if Trigger.notchPaused {
            return "Saved. The pointer is not held while opening from the notch is paused."
        }
        return model.cursorRestrictionStatus
    }

    // MARK: Permissions

    private var permissions: some View {
        SettingsPage {
            SettingsCard(footer: "Permissions are managed in macOS System Settings and checked again when you return to this window.") {
                permissionRow("Screen Recording",
                              detail: "Required. Displays the window you choose; Dropy saves no recording.",
                              granted: model.screenRecordingGranted,
                              action: model.openScreenRecordingSettings)
                permissionRow("Accessibility",
                              detail: "Needed to use apps in the overlay: Dropy moves the app's own window. Also used by the notch pointer restriction.",
                              granted: model.accessibilityGranted,
                              action: model.openAccessibilitySettings)
                if !model.screenRecordingGranted {
                    SettingsNotice(symbol: "arrow.clockwise", title: "Relaunch after allowing access",
                                   detail: "A new Screen Recording grant takes effect when Dropy opens again.") {
                        Button("Relaunch Dropy", action: model.relaunch)
                            .buttonStyle(SettingsButtonStyle())
                    }
                }
                SettingsRow("Permission Status", detail: "Access stays in your control.") {
                    Button("Check Again", action: model.refresh)
                        .buttonStyle(SettingsButtonStyle())
                }
            }
        }
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        SettingsRow(title, detail: detail) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(SettingsMetrics.bodyEmphasis)
                    .foregroundStyle(.green)
            } else {
                Button("Open System Settings…", action: action)
                    .buttonStyle(SettingsButtonStyle(outlined: true))
            }
        }
    }

    // MARK: About

    private var about: some View {
        SettingsPage {
            SettingsCard {
                HStack(spacing: SettingsMetrics.rowInset) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dropy").font(.system(size: 17, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Your apps, near the notch.")
                            .font(SettingsMetrics.detail).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: SettingsMetrics.rowInset)
                    Button("About Dropy", action: model.showAbout)
                        .buttonStyle(SettingsButtonStyle(outlined: true))
                }
                .padding(SettingsMetrics.rowInset)
            }

            SettingsCard("Details") {
                SettingsRow("Version") {
                    SettingsValue(model.versionText.replacingOccurrences(of: "Version ", with: ""))
                }
                SettingsRow("Location", detail: model.isInstalled ? "Applications" : "Development build") {
                    Button("Show in Finder", action: model.revealInFinder)
                        .buttonStyle(SettingsButtonStyle())
                }
                SettingsRow("License", detail: "Free and open source.") {
                    SettingsValue("MIT")
                }
                SettingsRow("Project Page", detail: "Source code, issues, and releases on GitHub.") {
                    Button("Open", action: model.openProjectPage)
                        .buttonStyle(SettingsButtonStyle())
                }
            }
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        SettingsPage {
            SettingsCard(footer: "The summary includes the app version, permissions, and preferences, never window titles or preview contents. Reset keeps Open at Login and macOS permissions.") {
                SettingsRow("Support Summary", detail: "Useful details for a bug report or support request.") {
                    Button(action: model.copySupportSummary) {
                        Label(model.supportSummaryCopied ? "Copied" : "Copy Summary",
                              systemImage: model.supportSummaryCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
                SettingsRow("Reset All Settings", detail: "Return Dropy to its original preferences.") {
                    Button("Reset to Defaults…", action: model.confirmReset)
                        .buttonStyle(SettingsButtonStyle(outlined: true))
                }
            }
        }
    }
}

private struct AppChooserSheet: View {
    @ObservedObject var model: SettingsModel

    private var trimmed: String { model.chooserQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filtered: [CatalogApp] {
        let q = trimmed
        guard !q.isEmpty else { return model.catalog }
        return model.catalog.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.bundleIdentifier.localizedCaseInsensitiveContains(q)
        }
    }

    private var running: [CatalogApp] { filtered.filter(\.running) }
    private var installed: [CatalogApp] { filtered.filter { !$0.running } }

    private var canChoose: Bool {
        model.chooserSelection.map { id in filtered.contains { $0.bundleIdentifier == id } } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose a pinned app").font(.title2.bold())
                    Text(model.isLoadingApps ? "Finding your apps…" : "Open directly into an app you use often.")
                        .font(SettingsMetrics.detail).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            TextField("Search apps", text: Binding(get: { model.chooserQuery }, set: { model.chooserQuery = $0 }))
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Group {
                if model.isLoadingApps {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: trimmed.isEmpty ? "apps" : trimmed)
                } else {
                    List(selection: Binding(get: { model.chooserSelection }, set: { model.chooserSelection = $0 })) {
                        if trimmed.isEmpty {
                            if !running.isEmpty {
                                Section("Running") { appRows(running, markRunning: false) }
                            }
                            if !installed.isEmpty {
                                Section("Installed") { appRows(installed, markRunning: false) }
                            }
                        } else {
                            appRows(filtered, markRunning: true)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Other App…", action: model.chooseOtherApp)
                Spacer()
                Button("Cancel") { model.isChoosingApp = false }
                    .keyboardShortcut(.cancelAction)
                Button("Pin App") { if let selected = model.chooserSelection { model.pin(selected) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canChoose)
            }
            .padding(16)
        }
        .frame(width: 500, height: 560)
    }

    private func appRows(_ rows: [CatalogApp], markRunning: Bool) -> some View {
        ForEach(rows) { app in
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                    if markRunning, app.running {
                        Text("Running").font(SettingsMetrics.detail).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .tag(app.bundleIdentifier)
        }
    }
}
