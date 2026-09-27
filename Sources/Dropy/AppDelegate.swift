import AppKit
import DropyCore

@main
@MainActor
final class DropyAppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = PreferenceStore()
    private var overlay: OverlayController!
    private var statusItem: NSStatusItem?
    private var trigger: NotchTrigger?
    private var hotKey: GlobalHotKey?
    private let placementJournal = PlacementJournal()
    private let parkingTabs = ParkingTabs()

    static func main() {
        let app = NSApplication.shared
        let delegate = DropyAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = OverlayController(preferences: preferences)
        // Undo placements left behind by a crash or forced quit before anything else.
        if !placementJournal.entries.isEmpty { placementJournal.restoreAll() }
        parkingTabs.onRestoreRequest = { [weak self] identity in
            guard let self,
                  let entry = self.placementJournal.entries.first(where: { $0.identity == identity }) else { return }
            let decision = WindowPlacer.restore(entry, journal: self.placementJournal)
            self.parkingTabs.remove(identity)
            NSLog("Dropy placement: tab clicked restore=%@", decision.map(PlacementJournal.name) ?? "pending")
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◆"
        item.button?.toolTip = "Dropy"
        let menu = NSMenu(title: "Dropy")
        hotKey = GlobalHotKey { [weak self] in self?.overlay.toggle() }
        let openTitle = hotKey == nil ? "Open Dropy" : "Open Dropy (\(GlobalHotKey.defaultDisplay))"
        menu.addItem(NSMenuItem(title: openTitle, action: #selector(toggleOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh windows", action: #selector(refresh), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Recover pending source windows…",
                                action: #selector(recoverPlacements), keyEquivalent: ""))
        menu.addItem(.separator())
        let triggers = NSMenu(title: "Notch trigger")
        for trigger in Trigger.allCases {
            let title = switch trigger {
            case .notchHover: "Hover"
            case .notchClick: "Click"
            case .shortcut: "Shortcut only"
            }
            let entry = NSMenuItem(title: title,
                                   action: #selector(changeTrigger(_:)), keyEquivalent: "")
            entry.representedObject = trigger.rawValue
            entry.state = preferences.value.trigger == trigger ? .on : .off
            triggers.addItem(entry)
        }
        let triggerItem = NSMenuItem(title: "Notch trigger", action: nil, keyEquivalent: "")
        triggerItem.submenu = triggers
        menu.addItem(triggerItem)
        let dismissals = NSMenu(title: "Dismiss")
        for behavior in [DismissBehavior.manual, .clickOutside, .pointerLeave] {
            let title = switch behavior {
            case .manual: "Esc or Close button only"
            case .clickOutside: "Click outside"
            case .pointerLeave: "Pointer leaves the overlay"
            }
            let entry = NSMenuItem(title: title, action: #selector(changeDismissBehavior(_:)), keyEquivalent: "")
            entry.representedObject = behavior.rawValue
            entry.state = preferences.value.dismissBehavior == behavior ? .on : .off
            entry.target = self
            dismissals.addItem(entry)
        }
        let dismissItem = NSMenuItem(title: "Dismiss", action: nil, keyEquivalent: "")
        dismissItem.submenu = dismissals
        menu.addItem(dismissItem)
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
        if let spec = environment["DROPY_DEBUG_PLACEMENT"] { runPlacementExperiment(spec) }
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
        hotKey?.unregister()
        placementJournal.restoreAll()
        parkingTabs.removeAll()
    }

    /// Development-only M2 experiment:
    /// `DROPY_DEBUG_PLACEMENT=<offscreen|minimize|hideApp|parked>[,<hold-seconds>]`. Once a
    /// preview is live, place the source window, hold, restore, and log capture
    /// continuity, how much of the window stayed visible, and whether the restore
    /// matched the original. Logs modes, counts and fractions only.
    private func runPlacementExperiment(_ spec: String) {
        let parts = spec.split(separator: ",").map(String.init)
        guard let mode = parts.first.flatMap(PlacementMode.init(rawValue:)) else {
            NSLog("Dropy placement: unknown mode")
            return
        }
        let hold = parts.count > 1 ? max(Double(parts[1]) ?? 10, 1) : 10
        Task { @MainActor [weak self] in
            guard let self else { return }
            var waited = 0
            while self.overlay.state != .viewing, waited < 15_000 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 100
            }
            guard let identity = self.overlay.currentSelection,
                  let before = self.overlay.captureCounts() else {
                NSLog("Dropy placement: mode=%@ skipped=noLivePreview", mode.rawValue)
                return
            }
            let entry: PlacementEntry
            do {
                entry = try await WindowPlacer.apply(mode, to: identity, journal: self.placementJournal)
            } catch {
                NSLog("Dropy placement: mode=%@ failed=%@", mode.rawValue, String(describing: error))
                return
            }
            try? await Task.sleep(for: .seconds(1))
            let displays = WindowPlacer.displayBounds()
            let server = WindowPlacer.windowServerInfo(identity.windowID)
            // A hidden or minimized window can drop out of the window-server list;
            // not being listed or not on screen both mean nothing is visible.
            var leak = server.map { $0.onScreen ? PlacementGeometry.visibleFraction(of: $0.bounds, on: displays) : 0 } ?? 0
            if mode == .parked, let server {
                // Whatever the tabs cover is out of sight; report only the remainder.
                let covered = self.parkingTabs.show(for: entry)
                let area = Double(server.bounds.width * server.bounds.height)
                let coveredArea = covered.reduce(0.0) { $0 + Double($1.width * $1.height) }
                leak = area > 0 ? max(leak - coveredArea / area, 0) : leak
                NSLog("Dropy placement: parked tabs=%ld coveredFraction=%.3f", covered.count,
                      area > 0 ? coveredArea / area : 0)
            }
            let placed = self.overlay.captureCounts() ?? before
            try? await Task.sleep(for: .seconds(hold))
            let held = self.overlay.captureCounts() ?? placed
            let stateDuringHold = self.overlay.state.diagnosticName
            let decision = WindowPlacer.restore(entry, journal: self.placementJournal)
            self.parkingTabs.remove(identity)
            try? await Task.sleep(for: .milliseconds(500))
            let restored = try? WindowPlacer.state(of: identity)
            let verified = restored.map { $0.approximatelyEquals(entry.original) }
            NSLog("Dropy placement: mode=%@ placedFrameLeak=%.3f windowServerLeak=%@ windowOnScreen=%@ overlay=%@ capture=%@ restore=%@ verified=%@",
                  mode.rawValue,
                  entry.applied.isMinimized || entry.applied.isAppHidden
                      ? 0 : PlacementGeometry.visibleFraction(of: entry.applied.frame, on: displays),
                  String(format: "%.3f", leak),
                  server.map { $0.onScreen ? "yes" : "no" } ?? "notListed",
                  stateDuringHold, held.delta(since: placed),
                  decision.map(PlacementJournal.name) ?? "pending",
                  verified.map { $0 ? "yes" : "no" } ?? "unknown")
        }
    }

    @objc private func recoverPlacements() {
        if placementJournal.loadError != nil {
            let alert = NSAlert()
            alert.messageText = "Window recovery journal could not be read"
            alert.informativeText = "The original file has been preserved at \(PlacementJournal.defaultURL.path). New placements are blocked until it can be read."
            alert.runModal()
            return
        }
        placementJournal.restoreAll()
        for entry in placementJournal.entries where entry.applicationConfirmed == false {
            let alert = NSAlert()
            alert.messageText = "Restore an interrupted window move?"
            alert.informativeText = "Dropy stopped before confirming this move. Restoring the original position may replace a later move you made."
            alert.addButton(withTitle: "Keep current position")
            alert.addButton(withTitle: "Restore original position")
            if alert.runModal() == .alertSecondButtonReturn,
               let current = try? WindowPlacer.state(of: entry.identity) {
                var confirmed = entry
                confirmed.applied = current
                confirmed.applicationConfirmed = true
                do {
                    try placementJournal.upsert(confirmed)
                    WindowPlacer.restore(confirmed, journal: placementJournal)
                } catch {
                    NSLog("Dropy explicit recovery journal failed: %@", String(describing: error))
                }
            }
        }
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

    @objc private func changeDismissBehavior(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let behavior = DismissBehavior(rawValue: raw) else { return }
        preferences.update { $0.dismissBehavior = behavior }
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
