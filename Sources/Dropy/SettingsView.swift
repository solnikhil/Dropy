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
        SettingsTopic(id: "about", pane: .general, title: "About and location",
                      detail: "Version, the project page, and this copy in Finder.",
                      keywords: "version mit license finder applications install"),
        SettingsTopic(id: "pin", pane: .opening, title: "App in the notch",
                      detail: "The app every opening shows, launched if it is not running.",
                      keywords: "pin pinned choose application favorite"),
        SettingsTopic(id: "trigger", pane: .opening, title: "Open from the notch",
                      detail: "Hover, click, or the shortcut only. Notch opening is paused.",
                      keywords: "hover click notch trigger"),
        SettingsTopic(id: "shortcut", pane: .opening, title: "Keyboard shortcut",
                      detail: "Opens and closes the overlay from anywhere.",
                      keywords: "hotkey shortcut keys option space"),
        SettingsTopic(id: "behavior", pane: .opening, title: "What opens",
                      detail: "The window picker, the saved app, or the last used app.",
                      keywords: "picker direct last used window"),
        SettingsTopic(id: "dismiss", pane: .opening, title: "Close the overlay",
                      detail: "Esc and Close, a click outside, or the pointer leaving.",
                      keywords: "dismiss close escape click outside pointer leave"),
        SettingsTopic(id: "size", pane: .overlay, title: "Size",
                      detail: "Compact, Medium, Wide, or the window's own size.",
                      keywords: "compact medium wide true size dimensions expand"),
        SettingsTopic(id: "fit", pane: .overlay, title: "Fit within the selected size",
                      detail: "Small windows keep their size. Larger ones scale down.",
                      keywords: "automatic scale native shrink"),
        SettingsTopic(id: "content", pane: .overlay, title: "Content",
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

    private var paneSelection: Binding<SettingsPane?> {
        Binding(get: { pane }, set: { new in
            // Setting the same pane again would wipe a search that only refreshed the list.
            guard let new, new.rawValue != paneRaw else { return }
            paneRaw = new.rawValue
        })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: paneSelection) {
                ForEach(SettingsPane.allCases) { item in
                    HStack(spacing: 8) {
                        SettingsIcon(symbol: item.symbol, tint: item.tint)
                        Text(item.title)
                    }
                    .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 188, ideal: 208, max: 240)
        } detail: {
            Group {
                if trimmedQuery.isEmpty {
                    paneBody
                } else {
                    searchResults
                }
            }
            .navigationTitle(trimmedQuery.isEmpty ? pane.title : "Search")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: Binding(get: { model.settingsQuery }, set: { model.settingsQuery = $0 }),
                    placement: .sidebar, prompt: "Search")
        .onAppear {
            if SettingsPane(rawValue: paneRaw) == nil { paneRaw = SettingsPane.general.rawValue }
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
                List(matches) { topic in
                    Button {
                        if paneRaw == topic.pane.rawValue { model.settingsQuery = "" }
                        else { paneRaw = topic.pane.rawValue }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(topic.title)
                            Text(topic.detail).font(.caption).foregroundStyle(.secondary)
                            Text(topic.pane.title).font(.caption).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dropy").font(.title2.bold())
                        Text(model.versionText).foregroundStyle(.secondary)
                        Text("Free and MIT-licensed.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 6) {
                        Button("About", action: model.showAbout)
                        Button("Project Page", action: model.openProjectPage)
                    }
                }
            } footer: {
                Text("The diamond stays in the menu bar. Settings is under that menu, and under ⌘,.")
            }

            Section("Startup") {
                Toggle(isOn: model.binding(\.showInDock)) {
                    Text("Show in Dock")
                    Text("Off leaves Dropy in the menu bar only. This window still shows a Dock icon while it is open, so Command-Tab can find it.")
                }
                Toggle("Open at login", isOn: model.opensAtLogin)
                loginStatus
            }

            Section("This copy") {
                LabeledContent("Location") {
                    HStack {
                        Text(model.isInstalled ? "Applications" : "Build folder")
                            .foregroundStyle(.secondary)
                        Button("Show in Finder", action: model.revealInFinder)
                    }
                }
                if !model.isInstalled {
                    Text("This copy runs from a build folder and is replaced on the next build. Run Scripts/install.sh before turning on Open at login.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
        Form {
            Section {
                pinnedRow
            } header: {
                Text("App in the notch")
            } footer: {
                Text("Every opening shows this app, and launches it when it is not running. Input still depends on the app and its version.")
            }

            Section("How it opens") {
                Picker("Open from the notch", selection: model.binding(\.trigger)) {
                    Text("On hover").tag(Trigger.notchHover)
                    Text("On click").tag(Trigger.notchClick)
                    Text("Shortcut only").tag(Trigger.shortcut)
                }
                .disabled(Trigger.notchPaused)
                if Trigger.notchPaused {
                    Text("Opening from the notch is paused. Use the shortcut. Your saved choice, \(triggerName), is kept for when this pause ends.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                shortcutRow
                Picker("Without a pinned app, show", selection: model.binding(\.openBehavior)) {
                    Text("The window picker").tag(OpenBehavior.picker)
                    Text("The saved app").tag(OpenBehavior.direct)
                    Text("The last used app").tag(OpenBehavior.lastUsed)
                }
                .disabled(model.preferences.pinnedBundleIdentifier != nil)
                Text(openDetail).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Saved app") {
                    Text(model.preferences.selectedBundleIdentifier.map(model.appName) ?? "None yet")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Last used") {
                    Text(model.preferences.lastUsedBundleIdentifier.map(model.appName) ?? "None yet")
                        .foregroundStyle(.secondary)
                }
                Picker("Close the overlay", selection: model.binding(\.dismissBehavior)) {
                    Text("With Esc or the Close button").tag(DismissBehavior.manual)
                    Text("When I click outside it").tag(DismissBehavior.clickOutside)
                    Text("When the pointer leaves it").tag(DismissBehavior.pointerLeave)
                }
                Text(dismissDetail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var pinnedRow: some View {
        HStack(spacing: 12) {
            if let pinned = model.pinnedApp {
                if let icon = pinned.icon {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(pinned.name).font(.headline)
                    Text("Opens in the overlay every time.").font(.caption).foregroundStyle(.secondary)
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
                    Text("No app pinned").font(.headline)
                    Text("Pin one to skip the window picker.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Choose App…", action: model.prepareAppList)
            }
        }
    }

    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Keyboard shortcut") {
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
            Text("Needs ⌘, ⌃ or ⌥, so a key you type is not taken over. Esc cancels a change.")
                .font(.caption).foregroundStyle(.secondary)
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
        Form {
            Section {
                Toggle("Fit the window within the selected size", isOn: model.binding(\.automaticWindowSize))
                Text("Small windows keep their native size. Larger windows scale down to Compact, Medium or Wide. Native size always shows the window at its own size, shrinking it only to fit the screen. Use Expand for more room.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(SizePreset.allCases, id: \.self) { preset in
                    sizeRow(preset)
                }
            } header: {
                Text("Size")
            }

            Section {
                Picker("Content", selection: model.binding(\.contentMode)) {
                    Text("Fit").tag(DropyCore.ContentMode.fit)
                    Text("Fill").tag(DropyCore.ContentMode.fill)
                    Text("Native scale").tag(DropyCore.ContentMode.nativeScale)
                }
                .pickerStyle(.radioGroup)
                Text(contentDetail).font(.caption).foregroundStyle(.secondary)
                if model.preferences.contentMode == .selectedRegion {
                    Text("The saved choice was a crop. This version does not offer one. Pick Fit, Fill or Native scale.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Picture")
            }
        }
        .formStyle(.grouped)
    }

    private func sizeRow(_ preset: SizePreset) -> some View {
        let selected = model.preferences.sizePreset == preset
        return Button {
            model.binding(\.sizePreset).wrappedValue = preset
        } label: {
            HStack(spacing: 10) {
                sizeMark(preset, selected: selected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                    Text(sizeDetail(preset)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sizeMark(_ preset: SizePreset, selected: Bool) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.18))
            Capsule()
                .fill(selected ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: 64 * sizeFraction(preset))
        }
        .frame(width: 64, height: 6)
        .accessibilityHidden(true)
    }

    private func sizeFraction(_ preset: SizePreset) -> CGFloat {
        switch preset {
        case .compact: 0.5
        case .medium: 0.75
        case .wide, .nativeSize: 1
        }
    }

    private func sizeDetail(_ preset: SizePreset) -> String {
        switch preset {
        case .nativeSize: return "The window's own size, shrunk only to fit the screen"
        default:
            let size = preset.dimensions
            return "\(Int(size.width)) × \(Int(size.height)) points, at most"
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
        Form {
            Section {
                Toggle(isOn: model.binding(\.interactivePreview)) {
                    Text("Interactive preview (beta)")
                    Text("Sends a click, a scroll or typed text only when that action was verified for the running app and version.")
                }
                if model.preferences.interactivePreview, !model.accessibilityGranted {
                    HStack {
                        Text("This needs Accessibility.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Allow…", action: model.openAccessibilitySettings)
                    }
                }
                Text("The evidence shipped with this build covers TextEdit 1.21 (a click in text, scrolling and typing) and Safari 27.0 (a click on a page button, and scrolling). Typing in Safari is refused. Any other app, or another version, stays view-only. The preview says why a gesture was refused.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Never sent: shortcuts, editing keys, right-click, drag, and input methods.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Preview")
            }

            Section {
                Toggle("Restrict sideways movement across the notch", isOn: model.binding(\.restrictNotchCrossing))
                if model.preferences.restrictNotchCrossing {
                    Text(crossingStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Stops the pointer at the shoulder while Dropy is closed. Requires Accessibility. Hold Option to bypass. Moving below the notch is always allowed. Off by default, and not yet checked on hardware.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Experimental")
            }
        }
        .formStyle(.grouped)
    }

    private var crossingStatus: String {
        if Trigger.notchPaused {
            return "Saved. The pointer is not held while opening from the notch is paused."
        }
        return model.cursorRestrictionStatus
    }

    // MARK: Permissions

    private var permissions: some View {
        Form {
            Section {
                PermissionCard(title: "Screen Recording",
                               detail: "Shows the window you pick inside the overlay. Dropy does not keep a recording.",
                               granted: model.screenRecordingGranted,
                               action: model.openScreenRecordingSettings)
                PermissionCard(title: "Accessibility",
                               detail: "Lets interactive preview reach the source window, and lets the experimental cursor restriction run.",
                               granted: model.accessibilityGranted,
                               action: model.openAccessibilitySettings)
            } footer: {
                Text("Dropy asks for a permission when you turn on the feature that needs it. Grants are checked again whenever this window becomes active.")
            }

            if !model.screenRecordingGranted {
                Section {
                    HStack {
                        Text("A Screen Recording grant applies only after Dropy opens again.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch Dropy", action: model.relaunch)
                    }
                }
            }

            Section {
                Button("Check Again", action: model.refresh)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Advanced

    private var advanced: some View {
        Form {
            Section {
                LabeledContent("Settings") {
                    Button("Reset to Defaults…", action: model.confirmReset)
                }
            } footer: {
                Text("Opening, the overlay, interaction, the Dock and the shortcut return to their defaults, and the pinned app is removed. Open at login is not changed.")
            }

            Section {
                LabeledContent("Support summary") {
                    Button("Copy", action: model.copySupportSummary)
                }
                if model.supportSummaryCopied {
                    Text("Copied to the clipboard.").font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("The summary has the version, the permission state and your choices. It has no window titles and nothing from the preview.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(tint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct Keycaps: View {
    let shortcut: KeyShortcut

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(shortcut.keycaps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, cap.count > 1 ? 7 : 6)
                    .frame(minWidth: 22)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.display)
    }
}

private struct PermissionCard: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.title3)
                .foregroundStyle(granted ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if granted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: action)
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
                    Text("Choose an app").font(.headline)
                    Text(model.isLoadingApps ? "Looking through Applications…" : "\(model.catalog.count) apps")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Other…", action: model.chooseOtherApp)
                Button("Cancel") { model.isChoosingApp = false }
                    .keyboardShortcut(.cancelAction)
                Button("Choose") { if let selected = model.chooserSelection { model.pin(selected) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canChoose)
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            TextField("Search apps", text: Binding(get: { model.chooserQuery }, set: { model.chooserQuery = $0 }))
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

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
        }
        .frame(width: 460, height: 540)
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
            .tag(app.bundleIdentifier)
        }
    }
}
