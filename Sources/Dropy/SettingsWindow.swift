import AppKit
import Combine
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
    /// Why the Dock could not be hidden, if it could not.
    @Published private(set) var dockProblem: String?
    /// The Dock's edge, read when Settings shows the position choice.
    var dockSide: DockSide { DockAutoHide.side }
    @Published var isChoosingApp = false
    @Published private(set) var catalog: [CatalogApp] = []
    @Published private(set) var isLoadingApps = false
    @Published private(set) var supportSummaryCopied = false
    /// Search in the settings sidebar. Held here because the local swiftc build
    /// does not load SwiftUI's State macro.
    @Published var settingsQuery = ""
    @Published var chooserQuery = ""
    /// The page on show, kept across launches, and the pages visited before and after
    /// it for the Back and Forward buttons.
    @Published private(set) var pane: SettingsPane
    @Published private var backStack: [SettingsPane] = []
    @Published private var forwardStack: [SettingsPane] = []
    private static let paneKey = "org.dropy.settings.pane"
    /// The sidebar's width, kept across launches, and its width when a drag began.
    @Published private(set) var sidebarWidth: CGFloat
    private var sidebarDragOrigin: CGFloat?
    private static let sidebarWidthKey = "org.dropy.settings.sidebarWidth"
    @Published var chooserSelection: String?
    /// The animations folder, set by the app delegate once it is watching it.
    var animations: AnimationLibrary? {
        didSet { animationsObservation = animations?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
    }
    private var animationsObservation: AnyCancellable?
    var updater: UpdateChecker? {
        didSet { updaterObservation = updater?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
    }
    private var updaterObservation: AnyCancellable?
    /// Plays an animation on the notch; returns how long it takes.
    var playOnNotch: ((DropyAnimation, Double) -> TimeInterval)?
    /// The animation in use, and why when it is not the one chosen.
    @Published private(set) var animationChoice = AnimationLibrary.Choice(animation: MotionStyle.balanced.animation)
    private var shortcutRecorder: Any?
    private var catalogGeneration = 0
    private let change: (_ edit: (inout DropyPreferences) -> Void) -> Void

    init(preferences: DropyPreferences,
         change: @escaping (_ edit: (inout DropyPreferences) -> Void) -> Void) {
        self.preferences = preferences
        self.change = change
        pane = UserDefaults.standard.string(forKey: Self.paneKey).flatMap(SettingsPane.init) ?? .general
        let savedWidth = UserDefaults.standard.double(forKey: Self.sidebarWidthKey)
        sidebarWidth = savedWidth > 0
            ? min(max(savedWidth, SettingsMetrics.sidebarWidth.lowerBound), SettingsMetrics.sidebarWidth.upperBound)
            : SettingsMetrics.sidebarDefaultWidth
        refresh()
    }

    // MARK: Sidebar width

    /// Follows a drag on the sidebar's edge; `translation` is measured from the drag's start.
    func resizeSidebar(by translation: CGFloat) {
        let origin = sidebarDragOrigin ?? sidebarWidth
        sidebarDragOrigin = origin
        let range = SettingsMetrics.sidebarWidth
        sidebarWidth = min(max(origin + translation, range.lowerBound), range.upperBound)
    }

    func endSidebarResize() {
        sidebarDragOrigin = nil
        UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
    }

    func setSidebarWidth(_ width: CGFloat) {
        let range = SettingsMetrics.sidebarWidth
        sidebarWidth = min(max(width, range.lowerBound), range.upperBound)
        UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
    }

    func resetSidebarWidth() { setSidebarWidth(SettingsMetrics.sidebarDefaultWidth) }

    // MARK: Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func navigate(to destination: SettingsPane) {
        settingsQuery = ""
        guard destination != pane else { return }
        backStack.append(pane)
        forwardStack.removeAll()
        show(destination)
    }

    func goBack() {
        guard let destination = backStack.popLast() else { return }
        forwardStack.append(pane)
        show(destination)
    }

    func goForward() {
        guard let destination = forwardStack.popLast() else { return }
        backStack.append(pane)
        show(destination)
    }

    private func show(_ destination: SettingsPane) {
        settingsQuery = ""
        stopRecordingShortcut()
        pane = destination
        UserDefaults.standard.set(destination.rawValue, forKey: Self.paneKey)
        if destination == .permissions { refresh() }
    }

    func animationChanged(_ choice: AnimationLibrary.Choice) {
        if animationChoice != choice { animationChoice = choice }
    }

    // MARK: Animations

    /// Opens a file from the animations folder in the Animation Studio.
    var openStudio: ((String) -> Void)?
    /// A short confirmation or problem under the animation actions.
    @Published private(set) var animationMessage: String?
    @Published private(set) var promptCopied = false

    var animationEntries: [AnimationLibrary.Entry] { animations?.entries ?? [] }

    func isInUse(_ id: String) -> Bool {
        preferences.customAnimation == id && animationChoice.problem == nil
    }

    func useAnimation(_ id: String) { change { $0.customAnimation = id } }

    func useBuiltIn(_ style: MotionStyle) {
        change {
            $0.motionStyle = style
            $0.customAnimation = nil
        }
    }

    /// A new file that starts as the animation in use, opened in the Studio.
    func newAnimation() {
        guard let animations else { return }
        var animation = animationChoice.animation
        let id = animations.freeID(for: "My Animation")
        animation.name = AnimationLibrary.title(for: id)
        animation.summary = ""
        animation.author = ""
        save(animation, as: id)
    }

    /// A new animation made at random, opened in the Studio to play with.
    func surpriseMe() {
        guard let animations else { return }
        var generator = SystemRandomNumberGenerator()
        let animation = DropyAnimation.surprise(using: &generator)
        save(animation, as: animations.freeID(for: animation.name))
    }

    /// Copies an example into the folder and opens it.
    func addExample(_ id: String) {
        guard let animations, let example = DropyAnimation.gallery.first(where: { $0.id == id })?.animation else { return }
        save(example, as: animations.freeID(for: example.name))
    }

    func duplicate(_ id: String) {
        guard let animations, var animation = animations.entry(id)?.animation else { return }
        animation.name += " Copy"
        save(animation, as: animations.freeID(for: animation.name))
    }

    private func save(_ animation: DropyAnimation, as id: String) {
        do {
            try animations?.save(animation, as: id)
            animationMessage = nil
            openStudio?(id)
        } catch {
            animationMessage = "Could not save the animation: \(error.localizedDescription)"
        }
    }

    func deleteAnimation(_ id: String) {
        if preferences.customAnimation == id { change { $0.customAnimation = nil } }
        animations?.delete(id)
        animationMessage = "Moved \(id).json to the Trash."
    }

    /// Reads a share code from the clipboard and adds the animation in it.
    func pasteShareCode() {
        guard let text = NSPasteboard.general.string(forType: .string),
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(AnimationFile.shareCodePrefix) else {
            animationMessage = "Copy a share code first: it starts with “\(AnimationFile.shareCodePrefix)”."
            return
        }
        let result = AnimationFile.read(shareCode: text)
        guard let animation = result.animation, let animations else {
            animationMessage = result.errors.first?.message ?? "That share code could not be read."
            return
        }
        save(animation, as: animations.freeID(for: animation.name))
    }

    func copyShareCode(_ id: String) {
        guard let animation = animations?.entry(id)?.animation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AnimationFile.shareCode(for: animation), forType: .string)
        animationMessage = "Copied the share code for “\(animation.name)”. Anyone with Dropy can paste it here."
    }

    func copyAIPrompt() {
        guard let animations else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AnimationGuide.prompt(folder: animations.shownFolder, command: AnimationLibrary.command),
                                       forType: .string)
        promptCopied = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.promptCopied = false
        }
    }

    func copyAnimationCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AnimationLibrary.command, forType: .string)
        animationMessage = "Copied the command. Run it with “help” to see what it does."
    }

    func showAnimationsFolder() {
        guard let animations else { return }
        animations.prepareFolder()
        NSWorkspace.shared.activateFileViewerSelecting([animations.folder.appendingPathComponent("README.md")])
    }

    func showInFinder(_ id: String) {
        guard let entry = animations?.entry(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
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
    func dockProblemChanged(_ problem: String?) { dockProblem = problem }

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
        return (appName(bundleID), icon(for: bundleID))
    }

    /// Finder's name for an app, or its identifier when it is gone.
    func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return "\(bundleID) (not installed)"
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    /// Opens the installed-app list. Scanning stays off the first drawing turn so the
    /// sheet can appear before hundreds of bundles are read.
    func prepareAppList() {
        stopRecordingShortcut()
        chooserQuery = ""
        chooserSelection = nil
        isChoosingApp = true
        isLoadingApps = true
        catalog = []
        catalogGeneration += 1
        let generation = catalogGeneration
        let running: [KnownApp] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  let bundleIdentifier = app.bundleIdentifier,
                  let path = app.bundleURL?.path else { return nil }
            return KnownApp(bundleIdentifier: bundleIdentifier, path: path)
        }
        Task { @MainActor in
            let apps = await Task.detached { AppCatalog.load(running: running) }.value
            guard generation == self.catalogGeneration else { return }
            self.catalog = apps
            self.isLoadingApps = false
        }
    }

    /// The sheet's Other… button. The open panel waits until the sheet is gone.
    func chooseOtherApp() {
        isChoosingApp = false
        Task { @MainActor in self.choosePinnedApp() }
    }

    func pin(_ bundleIdentifier: String) {
        isChoosingApp = false
        change { $0.pinnedBundleIdentifier = bundleIdentifier }
    }

    func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "macOS app workspace.\nFree and MIT-licensed."),
        ])
    }

    func openProjectPage() {
        if let url = URL(string: "https://github.com/solnikhil/Dropy") { NSWorkspace.shared.open(url) }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Bundle.main.bundlePath)])
    }

    /// Restores every saved choice. Open at login is a system registration, not one of
    /// those choices, so it is left alone.
    func confirmReset() {
        guard let window = NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.title == "Settings" && $0.isVisible }) else { return }
        let alert = NSAlert()
        alert.messageText = "Reset settings to defaults?"
        alert.informativeText = "Opening, the overlay, interaction, the Dock and the shortcut go back to their defaults, and the pinned app is removed. Open at login stays as it is."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                self?.shortcutProblem = nil
                self?.supportSummaryCopied = false
                self?.change { $0 = DropyPreferences() }
            }
        }
    }

    /// Version, permissions and choices. No window titles and no preview contents.
    var supportSummary: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let pin = preferences.pinnedBundleIdentifier.map(appName) ?? "none"
        return """
        Dropy \(version) (\(build))
        macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        Screen Recording: \(screenRecordingGranted ? "allowed" : "not allowed")
        Accessibility: \(accessibilityGranted ? "allowed" : "not allowed")
        Open at login: \(loginItemPhrase)
        Show in Dock: \(preferences.showInDock ? "on" : "off")
        Pinned app: \(pin)
        Open behavior: \(preferences.openBehavior.rawValue)
        Dismiss: \(preferences.dismissBehavior.rawValue)
        Size: \(preferences.sizePreset.rawValue)
        Content: \(preferences.contentMode.rawValue)
        Fit within size: \(preferences.automaticWindowSize ? "on" : "off")
        Use the app: \(preferences.interaction == .fullApp ? "full app" : "preview only")
        Keep pinned app ready: \(preferences.keepsPinnedAppReady ? "on" : "off")
        Animation: \(preferences.customAnimation.map { "custom (\($0))" } ?? preferences.motionStyle.rawValue)
        Notch crossing restriction: \(preferences.restrictNotchCrossing ? "on" : "off")
        Notch trigger saved: \(preferences.trigger.rawValue)
        Notch trigger in effect: \(preferences.trigger.effective.rawValue)
        Shortcut: \(preferences.shortcut.display)\(shortcutRegistered ? "" : " (not registered)")
        Installed in Applications: \(isInstalled ? "yes" : "no")
        """
    }

    func copySupportSummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(supportSummary, forType: .string)
        supportSummaryCopied = true
    }

    private var loginItemPhrase: String {
        switch loginItemStatus {
        case .enabled: "on"
        case .requiresApproval: "waiting for approval"
        case .notFound: "registered copy missing"
        case .notRegistered: "off"
        @unknown default: "unknown"
        }
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

/// An app Dropy can pin. `running` is filled in from the apps that were open when the list was built.
struct KnownApp: Sendable, Hashable {
    var bundleIdentifier: String
    var path: String
}

struct CatalogApp: Identifiable, Hashable, Sendable {
    var bundleIdentifier: String
    var name: String
    var path: String
    var running: Bool
    var id: String { bundleIdentifier }
}

enum AppCatalog {
    /// Applications, the home Applications folder, and system apps, one folder deeper
    /// so Utilities and similar groups are included. Dropy itself is left out.
    nonisolated static func load(running: [KnownApp]) -> [CatalogApp] {
        var urls: [URL] = []
        for root in roots { scan(root, into: &urls, depth: 0) }
        var byID: [String: CatalogApp] = [:]
        for url in urls { insert(url, running: false, into: &byID) }
        for app in running {
            if var existing = byID[app.bundleIdentifier] {
                existing.running = true
                existing.path = app.path
                byID[app.bundleIdentifier] = existing
            } else {
                insert(URL(fileURLWithPath: app.path), running: true, into: &byID, overrideID: app.bundleIdentifier)
            }
        }
        return byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static var roots: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        ]
    }

    private nonisolated static func scan(_ directory: URL, into found: inout [URL], depth: Int) {
        guard depth < 2,
              let items = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for item in items {
            if item.pathExtension.caseInsensitiveCompare("app") == .orderedSame { found.append(item) }
            else if depth == 0 { scan(item, into: &found, depth: 1) }
        }
    }

    private nonisolated static func insert(_ url: URL, running: Bool, into byID: inout [String: CatalogApp],
                                           overrideID: String? = nil) {
        let identifier = overrideID ?? Bundle(url: url)?.bundleIdentifier
        guard let identifier, identifier != "org.dropy.app", byID[identifier] == nil else { return }
        let raw = FileManager.default.displayName(atPath: url.path)
        let name = raw.hasSuffix(".app") ? String(raw.dropLast(4)) : raw
        guard !name.isEmpty else { return }
        byID[identifier] = CatalogApp(bundleIdentifier: identifier, name: name, path: url.path, running: running)
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
        let saved = UserDefaults.standard.string(forKey: "NSWindow Frame DropySettings5") != nil
        let created = window == nil
        let window = self.window ?? makeWindow()
        self.window = window
        model.refresh()
        if created, !saved { window.center() }
        window.makeKeyAndOrderFront(nil)
        onVisibilityChange?()
        NSApp.activate(ignoringOtherApps: true)
    }

    static let contentSize = CGSize(width: 920, height: 620)

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: SettingsView(model: model))
        // AppKit owns the window size; content adapts without resizing the window.
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.collectionBehavior.insert(.fullScreenNone)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = DropyAppearance.background
        // An empty unified toolbar gives the taller title area, which centers the
        // traffic lights beside the Back and Forward capsule drawn by SwiftUI.
        let toolbar = NSToolbar(identifier: "DropySettings")
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.setContentSize(Self.contentSize)
        window.contentMinSize = CGSize(width: 800, height: 560)
        window.setFrameAutosaveName("DropySettings5")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRecordingShortcut()
        // Ordered out after this returns; report once it is.
        DispatchQueue.main.async { [weak self] in self?.onVisibilityChange?() }
    }

    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }

    func windowDidResignKey(_ notification: Notification) {
        model.stopRecordingShortcut()
    }
}
