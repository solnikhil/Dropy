import AppKit
import ServiceManagement
import SwiftUI
import DropyCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, opening, overlay, interaction, permissions, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .opening: "Opening"
        case .overlay: "Overlay"
        case .interaction: "Interaction"
        case .permissions: "Permissions"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .opening: "macwindow.badge.plus"
        case .overlay: "rectangle.center.inset.filled"
        case .interaction: "hand.point.up.left.fill"
        case .permissions: "lock.shield.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "A little closer to everything you do."
        case .opening: "Your favorite windows, one shortcut away."
        case .overlay: "Make room for the way you work."
        case .interaction: "Choose how you work inside a preview."
        case .permissions: "You’re in control of what Dropy can access."
        case .advanced: "Support, diagnostics, and a fresh start."
        }
    }

    var tint: Color {
        switch self {
        case .general: Color(nsColor: .systemGray)
        case .opening: .blue
        case .overlay: .purple
        case .interaction: .orange
        case .permissions: .green
        case .advanced: Color(nsColor: .systemBrown)
        }
    }
}

private struct SettingsTopic: Identifiable {
    let id: String
    let pane: SettingsPane
    let title: String
    let detail: String
    let keywords: String

    static let all: [SettingsTopic] = [
        SettingsTopic(id: "dock", pane: .general, title: "Show in Dock",
                      detail: "A Dock icon and Dropy's own menu bar.",
                      keywords: "menu bar diamond icon dock"),
        SettingsTopic(id: "login", pane: .general, title: "Open at login",
                      detail: "Start Dropy when you log in.",
                      keywords: "login items startup launch"),
        SettingsTopic(id: "about", pane: .general, title: "About Dropy",
                      detail: "Version, the project page, and this copy in Finder.",
                      keywords: "version mit license finder applications install"),
        SettingsTopic(id: "pin", pane: .opening, title: "Pinned app",
                      detail: "The app every opening shows, launched if it is not running.",
                      keywords: "pin pinned choose application favorite"),
        SettingsTopic(id: "trigger", pane: .opening, title: "Open from the notch",
                      detail: "Hover, click, or the shortcut only. Notch opening is paused.",
                      keywords: "hover click notch trigger"),
        SettingsTopic(id: "shortcut", pane: .opening, title: "Open Dropy shortcut",
                      detail: "Opens and closes the overlay from anywhere.",
                      keywords: "hotkey shortcut keys option space"),
        SettingsTopic(id: "behavior", pane: .opening, title: "Show on opening",
                      detail: "The window picker, the saved app, or the last used app.",
                      keywords: "picker direct last used window"),
        SettingsTopic(id: "dismiss", pane: .opening, title: "Close the overlay",
                      detail: "Esc and Close, a click outside, or the pointer leaving.",
                      keywords: "dismiss close escape click outside pointer leave"),
        SettingsTopic(id: "size", pane: .overlay, title: "Size",
                      detail: "Compact, Medium, Wide, or the window's own size.",
                      keywords: "compact medium wide true size dimensions expand"),
        SettingsTopic(id: "fit", pane: .overlay, title: "Adapt to the window",
                      detail: "Small windows keep their size. Larger ones scale down.",
                      keywords: "automatic scale native shrink"),
        SettingsTopic(id: "content", pane: .overlay, title: "Content scaling",
                      detail: "Fit, Fill, or native size.",
                      keywords: "fit fill crop scale letterbox"),
        SettingsTopic(id: "interactive", pane: .interaction, title: "Interactive preview",
                      detail: "Sends only input verified for that app and version.",
                      keywords: "beta click scroll typing textedit safari"),
        SettingsTopic(id: "crossing", pane: .interaction, title: "Notch crossing",
                      detail: "Experimental hold on sideways movement across the notch.",
                      keywords: "cursor pointer experimental accessibility option"),
        SettingsTopic(id: "screen", pane: .permissions, title: "Screen Recording",
                      detail: "Shows the window you pick. A new grant needs a relaunch.",
                      keywords: "permission privacy capture screen recording"),
        SettingsTopic(id: "access", pane: .permissions, title: "Accessibility",
                      detail: "Needed for interactive preview and the cursor restriction.",
                      keywords: "permission privacy accessibility"),
        SettingsTopic(id: "reset", pane: .advanced, title: "Reset settings",
                      detail: "Restores the defaults. Open at login is left as it is.",
                      keywords: "reset defaults restore"),
        SettingsTopic(id: "support", pane: .advanced, title: "Support summary",
                      detail: "Copies version, permissions and choices. No window titles.",
                      keywords: "copy clipboard diagnostics support"),
    ]
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @AppStorage("org.dropy.settings.pane") private var paneRaw = SettingsPane.general.rawValue

    private var pane: SettingsPane { SettingsPane(rawValue: paneRaw) ?? .general }

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

    private var paneSelection: Binding<SettingsPane> {
        Binding(get: { pane }, set: { paneRaw = $0.rawValue })
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: paneSelection, model: model)
                .frame(width: 220)

            Group {
                if trimmedQuery.isEmpty {
                    paneBody.id(pane)
                } else {
                    searchResults
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .modifier(SettingsGlassSurface())
            .padding(.trailing, 10)
            .padding(.vertical, 8)
        }
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            if SettingsPane(rawValue: paneRaw) == nil { paneRaw = SettingsPane.general.rawValue }
        }
        .onChange(of: model.settingsQuery) { _, query in
            if !query.isEmpty { model.stopRecordingShortcut() }
        }
        .onChange(of: paneRaw) { _, new in
            model.settingsQuery = ""
            model.stopRecordingShortcut()
            if new == SettingsPane.permissions.rawValue { model.refresh() }
        }
        .sheet(isPresented: Binding(get: { model.isChoosingApp }, set: { model.isChoosingApp = $0 })) {
            AppChooserSheet(model: model)
        }
    }

    @ViewBuilder private var paneBody: some View {
        switch pane {
        case .general: general
        case .opening: opening
        case .overlay: overlay
        case .interaction: interaction
        case .permissions: permissions
        case .advanced: advanced
        }
    }

    private var searchResults: some View {
        Group {
            if matches.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                Form {
                    ForEach(SettingsPane.allCases) { resultPane in
                        let topics = matches.filter { $0.pane == resultPane }
                        if !topics.isEmpty {
                            Section(resultPane.title) {
                                ForEach(topics) { topic in
                                    Button {
                                        paneRaw = topic.pane.rawValue
                                        model.settingsQuery = ""
                                    } label: {
                                        HStack(spacing: 12) {
                                            SettingsIcon(symbol: topic.pane.symbol, tint: topic.pane.tint)
                                            SettingsLabel(topic.title, detail: topic.detail)
                                            Spacer(minLength: 12)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                        }
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: General

    private var general: some View {
        SettingsPage(pane: .general) {
            Section {
                Toggle(isOn: model.binding(\.showInDock)) {
                    SettingsLabel("Show in Dock", detail: "Keep Dropy in the Dock and the app switcher.")
                }
                .accessibilityLabel("Show in Dock")
                .accessibilityHint("Keep Dropy in the Dock and the app switcher.")
                Toggle(isOn: model.opensAtLogin) {
                    SettingsLabel("Open at login", detail: "Have Dropy ready when you start your Mac.")
                }
                .accessibilityLabel("Open at login")
                loginStatus
            } header: {
                Text("Startup & visibility")
            } footer: {
                Text("Dropy is always available in the menu bar. While Settings is open, it also appears in the Dock.")
            }

            Section("About Dropy") {
                LabeledContent("Version", value: model.versionText.replacingOccurrences(of: "Version ", with: ""))
                LabeledContent("Location") {
                    HStack(spacing: 10) {
                        Text(model.isInstalled ? "Applications" : "Development build").foregroundStyle(.secondary)
                        Button("Show in Finder", action: model.revealInFinder)
                    }
                }
                HStack {
                    SettingsLabel("Made for your Mac", detail: "Free, open source, and MIT-licensed.")
                    Spacer()
                    Button("Project Page", action: model.openProjectPage)
                    Button("About Dropy", action: model.showAbout)
                }
            }
            if !model.isInstalled {
                Section {
                    SettingsNotice(symbol: "app.badge", title: "Running a development copy",
                                   detail: "Move Dropy to Applications before enabling Open at login.")
                }
            }
        }
    }

    @ViewBuilder private var loginStatus: some View {
        if model.loginItemStatus == .requiresApproval {
            HStack {
                Text("Allow Dropy in Login Items to finish.").foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
        } else if model.loginItemStatus == .notFound {
            Text("macOS cannot find the registered copy. Turn this off and on from the app in Applications.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let error = model.loginItemError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: Opening

    private var opening: some View {
        SettingsPage(pane: .opening) {
            Section {
                shortcutRow
            } header: {
                Text("Keyboard shortcut")
            } footer: {
                Text("Open or close Dropy from any app. Use a combination that includes ⌘, ⌃, or ⌥.")
            }

            Section {
                pinnedRow
            } header: {
                Text("Pinned app")
            } footer: {
                Text("A pinned app opens every time. Dropy launches it for you when needed.")
            }

            Section {
                Picker("Show on opening", selection: model.binding(\.openBehavior)) {
                    Text("Window picker").tag(OpenBehavior.picker)
                    Text("Saved app").tag(OpenBehavior.direct)
                    Text("Last used app").tag(OpenBehavior.lastUsed)
                }
                .disabled(model.preferences.pinnedBundleIdentifier != nil)
                if model.preferences.openBehavior == .direct {
                    LabeledContent("Saved app", value: model.preferences.selectedBundleIdentifier.map(model.appName) ?? "Choose a window to save an app")
                } else if model.preferences.openBehavior == .lastUsed {
                    LabeledContent("Last used app", value: model.preferences.lastUsedBundleIdentifier.map(model.appName) ?? "None yet")
                }
            } header: {
                Text("Window selection")
            } footer: {
                Text(openDetail)
            }

            Section {
                Picker("Close the overlay", selection: model.binding(\.dismissBehavior)) {
                    Text("Manually").tag(DismissBehavior.manual)
                    Text("On click outside").tag(DismissBehavior.clickOutside)
                    Text("When the pointer leaves").tag(DismissBehavior.pointerLeave)
                }
            } header: {
                Text("Closing")
            } footer: {
                Text(dismissDetail)
            }

            Section {
                Picker("Open from the notch", selection: model.binding(\.trigger)) {
                    Text("On hover").tag(Trigger.notchHover)
                    Text("On click").tag(Trigger.notchClick)
                    Text("Shortcut only").tag(Trigger.shortcut)
                }
                .disabled(Trigger.notchPaused)
                if Trigger.notchPaused {
                    SettingsNotice(symbol: "pause.circle", title: "Notch opening is temporarily unavailable",
                                   detail: "Use your keyboard shortcut. Your preference, “\(triggerName),” is saved.")
                }
            } header: {
                Text("Notch activation")
            }
        }
    }

    private var pinnedRow: some View {
        HStack(spacing: 12) {
            if let pinned = model.pinnedApp {
                if let icon = pinned.icon {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(pinned.name).font(.headline)
                    Text("Your go-to app, always within reach.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Change…", action: model.prepareAppList)
                Button("Remove", action: model.unpin)
            } else {
                Image(systemName: "macwindow")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose your go-to app").font(.headline)
                    Text("Open straight into an app you use often.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Choose App…", action: model.prepareAppList)
            }
        }
    }

    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Open Dropy") {
                HStack(spacing: 8) {
                    if model.isRecordingShortcut {
                        Text("Press the new shortcut…").foregroundStyle(.secondary)
                        Button("Cancel", action: model.stopRecordingShortcut)
                    } else {
                        Keycaps(shortcut: model.preferences.shortcut)
                            .opacity(model.shortcutRegistered ? 1 : 0.45)
                        if model.preferences.shortcut != .default {
                            Button("Reset", action: model.resetShortcut)
                        }
                        Button("Change…", action: model.recordShortcut)
                    }
                }
            }
            if let problem = model.shortcutProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if !model.shortcutRegistered {
                Text("Another app uses \(model.preferences.shortcut.display), so it does nothing. Choose a different one.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
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
            "Esc, ⌘W and the Close button close it. A click outside leaves it open."
        case .clickOutside:
            "A click outside the overlay closes it. Esc, ⌘W and the Close button still work."
        case .pointerLeave:
            "The overlay closes after the pointer leaves it. Esc, ⌘W and the Close button still work."
        }
    }

    // MARK: Overlay

    private var overlay: some View {
        SettingsPage(pane: .overlay) {
            Section {
                OverlaySizePreview(preset: model.preferences.sizePreset)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                Picker("Overlay size", selection: model.binding(\.sizePreset)) {
                    ForEach(SizePreset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Overlay size")
                .padding(.bottom, 6)
            } header: {
                Text("Size")
            } footer: {
                Text(sizeDetail(model.preferences.sizePreset))
            }

            Section {
                Toggle(isOn: model.binding(\.automaticWindowSize)) {
                    SettingsLabel("Adapt to the window", detail: "Keep smaller windows at their original size.")
                }
                .accessibilityLabel("Adapt to the window")
                .disabled(model.preferences.sizePreset == .nativeSize)
            } footer: {
                Text(model.preferences.sizePreset == .nativeSize
                     ? "Native size follows the original window, shrinking only to fit your screen."
                     : "Larger windows scale down to the selected size. Expand the overlay whenever you need more room.")
            }

            Section {
                Picker("Content scaling", selection: model.binding(\.contentMode)) {
                    Text("Fit entire window").tag(DropyCore.ContentMode.fit)
                    Text("Fill overlay").tag(DropyCore.ContentMode.fill)
                    Text("Native scale").tag(DropyCore.ContentMode.nativeScale)
                    if model.preferences.contentMode == .selectedRegion {
                        Text("Selected region (unavailable)").tag(DropyCore.ContentMode.selectedRegion)
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text(contentDetail)
            }
        }
    }

    private func sizeDetail(_ preset: SizePreset) -> String {
        switch preset {
        case .nativeSize: return "Use the window’s original size, up to the available screen space."
        default:
            let size = preset.dimensions
            return "Up to \(Int(size.width)) × \(Int(size.height)) points. The preview above illustrates the relative size."
        }
    }

    private var contentDetail: String {
        switch model.preferences.contentMode {
        case .fit:
            "The whole window stays visible. Empty space remains when its shape differs from the overlay."
        case .fill:
            "The overlay is filled. Edges of the window can sit outside the preview."
        case .nativeScale:
            "One point of the window is one point on screen, until the window is larger than the overlay."
        case .selectedRegion:
            "A chosen region is not available."
        }
    }

    // MARK: Interaction

    private var interaction: some View {
        SettingsPage(pane: .interaction) {
            Section {
                Toggle(isOn: model.binding(\.interactivePreview)) {
                    HStack(spacing: 8) {
                        SettingsLabel("Interactive preview", detail: "Click, scroll, and type in supported apps.")
                        SettingsBadge("Beta")
                    }
                }
                .accessibilityLabel("Interactive preview, beta")
                if model.preferences.interactivePreview, !model.accessibilityGranted {
                    HStack(spacing: 12) {
                        SettingsNotice(symbol: "hand.raised", title: "Accessibility access required",
                                       detail: "Allow Dropy to send input to the source window.")
                        Spacer()
                        Button("Open Settings…", action: model.openAccessibilitySettings)
                    }
                }
            } header: {
                Text("Preview controls")
            } footer: {
                Text("Input is enabled only for actions verified with the running app and version. Other apps remain view-only.")
            }

            Section {
                compatibilityRow("TextEdit", version: "1.21", symbol: "doc.text", detail: "Click in text, scroll, and type")
                compatibilityRow("Safari", version: "27.0", symbol: "safari", detail: "Click page buttons and scroll")
            } header: {
                Text("Supported in this build")
            } footer: {
                Text("Safari typing, keyboard shortcuts, editing keys, right-click, dragging, and input methods are not supported.")
            }

            Section {
                Toggle(isOn: model.binding(\.restrictNotchCrossing)) {
                    SettingsLabel("Keep the pointer beside the notch", detail: "Restrict sideways movement while Dropy is closed.")
                }
                .accessibilityLabel("Keep the pointer beside the notch")
                if model.preferences.restrictNotchCrossing {
                    SettingsNotice(symbol: "info.circle", title: "Notch restriction", detail: crossingStatus)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Notch crossing")
                    SettingsBadge("Experimental")
                }
            } footer: {
                Text("Requires Accessibility. Hold Option to cross, or move below the notch. This feature has not yet been verified on hardware.")
            }
        }
    }

    private func compatibilityRow(_ name: String, version: String, symbol: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
                .frame(width: 32).accessibilityHidden(true)
            SettingsLabel(name, detail: detail)
            Spacer()
            Text(version).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var crossingStatus: String {
        if Trigger.notchPaused {
            return "Saved. The pointer is not held while opening from the notch is paused."
        }
        return model.cursorRestrictionStatus
    }

    // MARK: Permissions

    private var permissions: some View {
        SettingsPage(pane: .permissions) {
            Section {
                PermissionCard(title: "Screen Recording", symbol: "rectangle.inset.filled.on.rectangle",
                               detail: "Display the window you choose in the overlay. Dropy does not save a recording.",
                               requirement: "Required for window previews",
                               granted: model.screenRecordingGranted,
                               action: model.openScreenRecordingSettings)
            }
            Section {
                PermissionCard(title: "Accessibility", symbol: "accessibility",
                               detail: "Send input to supported apps and enable the optional notch pointer restriction.",
                               requirement: "Optional • Used for interaction",
                               granted: model.accessibilityGranted,
                               action: model.openAccessibilitySettings)
            } footer: {
                Text("Permissions are managed in macOS System Settings and checked again when you return to this window.")
            }
            if !model.screenRecordingGranted {
                Section {
                    HStack(spacing: 12) {
                        SettingsNotice(symbol: "arrow.clockwise", title: "Relaunch after allowing access",
                                       detail: "A new Screen Recording grant takes effect when Dropy opens again.")
                        Spacer(minLength: 8)
                        Button("Relaunch Dropy", action: model.relaunch)
                    }
                }
            }
            Section {
                HStack {
                    Label("Access stays in your control", systemImage: "hand.raised")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Again", action: model.refresh)
                }
            }
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        SettingsPage(pane: .advanced) {
            Section {
                HStack(spacing: 16) {
                    SettingsLabel("Support summary", detail: "Useful details for a bug report or support request.")
                    Spacer(minLength: 8)
                    Button(action: model.copySupportSummary) {
                        Label(model.supportSummaryCopied ? "Copied" : "Copy Summary",
                              systemImage: model.supportSummaryCopied ? "checkmark" : "doc.on.doc")
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Includes the app version, permissions, and preferences. Window titles and preview contents are never included.")
            }

            Section {
                HStack(spacing: 16) {
                    SettingsLabel("Reset all settings", detail: "Return Dropy to its original preferences.")
                    Spacer(minLength: 8)
                    Button("Reset to Defaults…", action: model.confirmReset)
                }
            } header: {
                Text("Reset")
            } footer: {
                Text("Resets opening, overlay, interaction, Dock visibility, and the shortcut, and removes your pinned app. Open at login and macOS permissions are kept.")
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
                        .font(.caption).foregroundStyle(.secondary)
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
                        Text("Running").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .tag(app.bundleIdentifier)
        }
    }
}
