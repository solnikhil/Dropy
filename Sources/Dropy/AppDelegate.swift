import AppKit
import DropyCore

@main
@MainActor
final class DropyAppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = PreferenceStore()
    private var overlay: OverlayController!
    private var statusItem: NSStatusItem?
    private var trigger: NotchTrigger?

    static func main() {
        let app = NSApplication.shared
        let delegate = DropyAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = OverlayController(preferences: preferences)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◆"
        item.button?.toolTip = "Dropy"
        let menu = NSMenu(title: "Dropy")
        menu.addItem(NSMenuItem(title: "Open Dropy", action: #selector(toggleOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh windows", action: #selector(refresh), keyEquivalent: ""))
        menu.addItem(.separator())
        let triggers = NSMenu(title: "Notch trigger")
        for trigger in [Trigger.notchHover, .notchClick] {
            let entry = NSMenuItem(title: trigger == .notchHover ? "Hover" : "Click",
                                   action: #selector(changeTrigger(_:)), keyEquivalent: "")
            entry.representedObject = trigger.rawValue
            entry.state = preferences.value.trigger == trigger ? .on : .off
            triggers.addItem(entry)
        }
        let triggerItem = NSMenuItem(title: "Notch trigger", action: nil, keyEquivalent: "")
        triggerItem.submenu = triggers
        menu.addItem(triggerItem)
        let sizes = NSMenu(title: "Overlay size")
        for preset in SizePreset.allCases {
            let entry = NSMenuItem(title: preset.rawValue.capitalized,
                                   action: #selector(changeSize(_:)), keyEquivalent: "")
            entry.representedObject = preset.rawValue
            entry.state = preferences.value.sizePreset == preset ? .on : .off
            sizes.addItem(entry)
        }
        let sizeItem = NSMenuItem(title: "Overlay size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)
        let openModes = NSMenu(title: "Open behavior")
        for mode in OpenBehavior.allCases {
            let entry = NSMenuItem(title: mode.rawValue == "lastUsed" ? "Last used" : mode.rawValue.capitalized,
                                   action: #selector(changeOpenBehavior(_:)), keyEquivalent: "")
            entry.representedObject = mode.rawValue
            entry.state = preferences.value.openBehavior == mode ? .on : .off
            openModes.addItem(entry)
        }
        let openItem = NSMenuItem(title: "Open behavior", action: nil, keyEquivalent: "")
        openItem.submenu = openModes
        menu.addItem(openItem)
        let contentModes = NSMenu(title: "Content view")
        for mode in [ContentMode.fit, .fill, .nativeScale] {
            let title = mode == .nativeScale ? "Native scale" : mode.rawValue.capitalized
            let entry = NSMenuItem(title: title, action: #selector(changeContentMode(_:)), keyEquivalent: "")
            entry.representedObject = mode.rawValue
            entry.state = preferences.value.contentMode == mode ? .on : .off
            contentModes.addItem(entry)
        }
        let contentItem = NSMenuItem(title: "Content view", action: nil, keyEquivalent: "")
        contentItem.submenu = contentModes
        menu.addItem(contentItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Dropy", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items { if entry.action != nil { entry.target = self } }
        for entry in sizes.items { entry.target = self }
        for entry in openModes.items { entry.target = self }
        for entry in triggers.items { entry.target = self }
        for entry in contentModes.items { entry.target = self }
        item.menu = menu
        statusItem = item

        let trigger = NotchTrigger(mode: { [weak self] in self?.preferences.value.trigger ?? .notchHover },
                                   isArmed: { [weak self] in self?.overlay.state == .closed },
                                   open: { [weak self] in self?.overlay.open() })
        trigger.start()
        self.trigger = trigger
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.async { [weak self] in self?.overlay.open() }
        }
        startDebugDriversIfRequested()
    }

    /// Development-only drivers for repeatable measurements without input automation.
    /// - `DROPY_DEBUG_CYCLES=<n>[,<hold-ms>]`: open, wait for a live preview (or a failure,
    ///   up to ten seconds), hold, close; repeat n times.
    /// - `DROPY_DEBUG_QUIT_AFTER=<seconds>`: close the overlay and quit, so every
    ///   capture logs its metrics summary.
    private func startDebugDriversIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        if let spec = environment["DROPY_DEBUG_CYCLES"] {
            let parts = spec.split(separator: ",").compactMap { Int($0) }
            let cycles = max(parts.first ?? 10, 1)
            let hold = parts.count > 1 ? max(parts[1], 0) : 1_000
            Task { @MainActor [weak self] in
                for cycle in 1...cycles {
                    guard let self else { return }
                    if self.overlay.state == .closed { self.overlay.open() }
                    var waited = 0
                    while self.overlay.state != .viewing, self.overlay.state.failure == nil, waited < 10_000 {
                        try? await Task.sleep(for: .milliseconds(50))
                        waited += 50
                    }
                    NSLog("Dropy debug cycle %ld: %@", cycle, self.overlay.state.diagnosticName)
                    try? await Task.sleep(for: .milliseconds(hold))
                    self.overlay.close()
                    try? await Task.sleep(for: .milliseconds(300))
                }
                NSLog("Dropy debug cycles done")
            }
        }
        if let seconds = environment["DROPY_DEBUG_QUIT_AFTER"].flatMap(Double.init) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.overlay.close()
                try? await Task.sleep(for: .milliseconds(500))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        trigger?.stop()
    }

    @objc private func toggleOverlay() { overlay.toggle() }
    @objc private func refresh() { if overlay.state == .closed { overlay.open() } else { overlay.refreshWindows() } }
    @objc private func quit() { overlay.close(); NSApp.terminate(nil) }

    @objc private func changeSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let size = SizePreset(rawValue: raw) else { return }
        preferences.update { $0.sizePreset = size }
        updateChecks(in: sender.menu, selected: sender)
        if overlay.state != .closed { overlay.close(); overlay.open() }
    }

    @objc private func changeTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let trigger = Trigger(rawValue: raw) else { return }
        preferences.update { $0.trigger = trigger }
        updateChecks(in: sender.menu, selected: sender)
    }

    @objc private func changeContentMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ContentMode(rawValue: raw) else { return }
        preferences.update { $0.contentMode = mode }
        updateChecks(in: sender.menu, selected: sender)
        if overlay.state != .closed { overlay.close(); overlay.open() }
    }

    @objc private func changeOpenBehavior(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = OpenBehavior(rawValue: raw) else { return }
        preferences.update { $0.openBehavior = mode }
        updateChecks(in: sender.menu, selected: sender)
    }

    private func updateChecks(in menu: NSMenu?, selected: NSMenuItem) {
        for item in menu?.items ?? [] { item.state = item === selected ? .on : .off }
    }
}
