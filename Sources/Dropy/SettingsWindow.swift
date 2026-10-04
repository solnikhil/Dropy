import AppKit
import ServiceManagement
import SwiftUI
import DropyCore

/// What the Settings window shows and changes. Every preference edit goes through
/// `change`, so the window, the menus and the overlay share one set of side effects.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var preferences: DropyPreferences
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    @Published private(set) var loginItemError: String?
    /// False when another app owns the saved shortcut, so it does nothing.
    @Published var shortcutRegistered = true
    @Published var cursorRestrictionStatus = "Off"
    @Published private(set) var isRecordingShortcut = false
    @Published private(set) var shortcutProblem: String?
    private var shortcutRecorder: Any?
    private let change: (_ edit: (inout DropyPreferences) -> Void) -> Void

    init(preferences: DropyPreferences,
         change: @escaping (_ edit: (inout DropyPreferences) -> Void) -> Void) {
        self.preferences = preferences
        self.change = change
        refresh()
    }

    /// Called by the app delegate after any change, wherever it came from.
    func preferencesChanged(_ preferences: DropyPreferences) {
        if self.preferences != preferences { self.preferences = preferences }
    }

    /// Permissions and the login item change in System Settings, outside Dropy.
    func refresh() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
        loginItemStatus = SMAppService.mainApp.status
    }

    func binding<Value>(_ keyPath: WritableKeyPath<DropyPreferences, Value> & Sendable) -> Binding<Value> {
        Binding(get: { self.preferences[keyPath: keyPath] },
                set: { value in self.change { $0[keyPath: keyPath] = value } })
    }

    var opensAtLogin: Binding<Bool> {
        Binding(get: { self.loginItemStatus == .enabled || self.loginItemStatus == .requiresApproval },
                set: { self.setOpensAtLogin($0) })
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refresh()
    }

    /// A login item points at this copy of the app; a build folder copy is replaced on
    /// every build, so recommend the installed one.
    var isInstalled: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/")
    }

    func openScreenRecordingSettings() {
        // Asking registers Dropy in the list, so the person has something to switch on.
        if !CGRequestScreenCaptureAccess() {
            Self.openPrivacyPane("Privacy_ScreenCapture")
        }
        refresh()
    }

    func openAccessibilitySettings() {
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            Self.openPrivacyPane("Privacy_Accessibility")
        }
        refresh()
    }

    // MARK: Shortcut recording

    /// Takes the next key pressed with Command, Control or Option as the shortcut.
    /// Esc cancels.
    func recordShortcut() {
        stopRecordingShortcut()
        shortcutProblem = nil
        isRecordingShortcut = true
        shortcutRecorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.recorded(event)
            return nil
        }
    }

    func stopRecordingShortcut() {
        if let shortcutRecorder { NSEvent.removeMonitor(shortcutRecorder) }
        shortcutRecorder = nil
        isRecordingShortcut = false
    }

    func resetShortcut() {
        shortcutProblem = nil
        change { $0.shortcut = .default }
    }

    func shortcutRejected(_ problem: String) { shortcutProblem = problem }

    private func recorded(_ event: NSEvent) {
        if event.keyCode == 53 {
            stopRecordingShortcut()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= KeyShortcut.command }
        if flags.contains(.shift) { modifiers |= KeyShortcut.shift }
        if flags.contains(.option) { modifiers |= KeyShortcut.option }
        if flags.contains(.control) { modifiers |= KeyShortcut.control }
        let shortcut = KeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers,
                                   display: KeyShortcut.symbols(for: modifiers) + Self.keyName(event))
        guard shortcut.isAcceptable else {
            shortcutProblem = "Include ⌘, ⌃ or ⌥ so the shortcut does not take over a key you type."
            return
        }
        guard !GlobalHotKey.systemConflict(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) else {
            shortcutProblem = "macOS already uses \(shortcut.display). Choose a different one."
            return
        }
        stopRecordingShortcut()
        shortcutProblem = nil
        change { $0.shortcut = shortcut }
    }

    /// The key as menus show it: a letter or digit, or a symbol for special keys.
    private static func keyName(_ event: NSEvent) -> String {
        let special: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = special[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    /// The pinned app as Finder shows it, or nil when nothing is pinned. An app that
    /// was removed keeps its identifier as the name, so the person sees what is pinned.
    var pinnedApp: (name: String, icon: NSImage?)? {
        guard let bundleID = preferences.pinnedBundleIdentifier else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return ("\(bundleID) (not installed)", nil)
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return (name.hasSuffix(".app") ? String(name.dropLast(4)) : name, NSWorkspace.shared.icon(forFile: url.path))
    }

    func choosePinnedApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose the app to show in the notch"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url,
                  let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.change { $0.pinnedBundleIdentifier = bundleID } }
        }
    }

    func unpin() { change { $0.pinnedBundleIdentifier = nil } }

    /// macOS applies a new Screen Recording grant only to a fresh process.
    func relaunch() {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? script.run()
        NSApp.terminate(nil)
    }

    private static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
        Form {
            Section {
                HStack(spacing: 12) {
                    if let pinned = model.pinnedApp {
                        if let icon = pinned.icon {
                            Image(nsImage: icon).resizable().frame(width: 36, height: 36)
                        }
                        VStack(alignment: .leading) {
                            Text(pinned.name)
                            Text("Opens in the overlay every time, launched if needed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Change…", action: model.choosePinnedApp)
                        Button("Remove", action: model.unpin)
                    } else {
                        VStack(alignment: .leading) {
                            Text("No app pinned")
                            Text("Pin an app to see it whenever the overlay opens.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Choose App…", action: model.choosePinnedApp)
                    }
                }
            } header: {
                Text("App in the notch")
            } footer: {
                Text("Input support depends on the selected app and window.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Opening") {
                Picker("Open from the notch", selection: model.binding(\.trigger)) {
                    Text("On hover").tag(Trigger.notchHover)
                    Text("On click").tag(Trigger.notchClick)
                    Text("Never (shortcut only)").tag(Trigger.shortcut)
                }
                LabeledContent("Keyboard shortcut") {
                    HStack {
                        if model.isRecordingShortcut {
                            Text("Press the new shortcut…").foregroundStyle(.secondary)
                            Button("Cancel", action: model.stopRecordingShortcut)
                        } else {
                            Text(model.preferences.shortcut.display)
                                .foregroundStyle(model.shortcutRegistered ? .primary : .secondary)
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
                Picker("Without a pinned app, show", selection: model.binding(\.openBehavior)) {
                    Text("The window picker").tag(OpenBehavior.picker)
                    Text("The saved app").tag(OpenBehavior.direct)
                    Text("The last used app").tag(OpenBehavior.lastUsed)
                }
                .disabled(model.preferences.pinnedBundleIdentifier != nil)
                Picker("Close the overlay", selection: model.binding(\.dismissBehavior)) {
                    Text("With Esc or the Close button").tag(DismissBehavior.manual)
                    Text("When I click outside it").tag(DismissBehavior.clickOutside)
                    Text("When the pointer leaves it").tag(DismissBehavior.pointerLeave)
                }
            }

            Section("Overlay") {
                Toggle("Fit the window within the selected size", isOn: model.binding(\.automaticWindowSize))
                Text("Small windows keep their native size. Larger windows scale down to Compact, Medium or Wide. True size always shows the window at its own size, shrinking it only to fit the screen. Use Expand for more room.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Size", selection: model.binding(\.sizePreset)) {
                    Text("Compact").tag(SizePreset.compact)
                    Text("Medium").tag(SizePreset.medium)
                    Text("Wide").tag(SizePreset.wide)
                    Text("True size").tag(SizePreset.trueSize)
                }
                .pickerStyle(.segmented)
                Picker("Content", selection: model.binding(\.contentMode)) {
                    Text("Fit").tag(DropyCore.ContentMode.fit)
                    Text("Fill").tag(DropyCore.ContentMode.fill)
                    Text("Native scale").tag(DropyCore.ContentMode.nativeScale)
                }
                .pickerStyle(.segmented)
                Toggle(isOn: model.binding(\.interactivePreview)) {
                    Text("Interactive preview (beta)")
                    Text("Sends clicks, scrolling and typing to the source window, only for input verified on that app.")
                }
            }

            Section("Experimental") {
                Toggle("Restrict sideways movement across the notch", isOn: model.binding(\.restrictNotchCrossing))
                if model.preferences.restrictNotchCrossing {
                    Text(model.cursorRestrictionStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Stops the pointer at the shoulder while Dropy is closed. Requires Accessibility. Hold Option to bypass; moving below the notch is always allowed. Off by default; device validation pending.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("App") {
                Toggle(isOn: model.binding(\.showInDock)) {
                    Text("Show in Dock")
                    Text("When off, Dropy lives only in the menu bar.")
                }
                Toggle("Open at login", isOn: model.opensAtLogin)
                if model.loginItemStatus == .requiresApproval {
                    HStack {
                        Text("Allow Dropy in Login Items to finish.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if !model.isInstalled {
                    Text("This copy runs from a build folder. Run Scripts/install.sh to put Dropy in Applications before turning on Open at login.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Permissions") {
                PermissionRow(title: "Screen Recording", detail: "Shows the window you pick.",
                              granted: model.screenRecordingGranted, action: model.openScreenRecordingSettings)
                PermissionRow(title: "Accessibility", detail: "Needed for interactive preview and the experimental cursor restriction.",
                              granted: model.accessibilityGranted, action: model.openAccessibilitySettings)
                if !model.screenRecordingGranted {
                    HStack {
                        Text("Switched Dropy on already? macOS applies it after Dropy reopens.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch Dropy", action: model.relaunch)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 480, height: 560)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: action)
            }
        }
    }
}

/// The Settings window. It is created on first use and kept, so reopening is instant.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    /// Called when the window appears or closes, so the app can show its Dock icon
    /// while Settings is open even when "Show in Dock" is off.
    var onVisibilityChange: (() -> Void)?
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        model.refresh()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        onVisibilityChange?()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = "Dropy Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DropySettings")
        window.setContentSize(CGSize(width: 480, height: 560))
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRecordingShortcut()
        // Ordered out after this returns; report once it is.
        DispatchQueue.main.async { [weak self] in self?.onVisibilityChange?() }
    }

    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }
}
