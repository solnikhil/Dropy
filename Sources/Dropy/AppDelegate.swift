import AppKit
import DropyCore

@main
@MainActor
final class DropyAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preferences = PreferenceStore()
    private var overlay: OverlayController!
    private var statusItem: NSStatusItem?
    private var trigger: NotchTrigger?
    private var hotKey: GlobalHotKey?
    private var sourceTerminationObserver: NSObjectProtocol?
    private let placementJournal = PlacementJournal()
    private let parkingTabs = ParkingTabs()
    private lazy var recovery = PlacementRecovery(journal: placementJournal)
    private lazy var handOff = HandOffSession(journal: placementJournal)

    static func main() {
        let app = NSApplication.shared
        let delegate = DropyAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Status menus can be tracked by the system without an NSEvent reaching our
    /// local/global monitors. Opening this menu is an outside interaction regardless
    /// of which process owns its mouse event; the dismissal preference decides.
    func menuWillOpen(_ menu: NSMenu) {
        overlay?.dismiss(.clickOutside)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = OverlayController(preferences: preferences, inputRouter: InputRouter(journal: placementJournal),
                                   handOff: handOff,
                                   containment: SourceContainmentReader(journal: placementJournal, tabs: parkingTabs))
        // A handed-over window is the person's again: no tab may cover it, and a tab comes
        // back only when the end of a hand-off parked it again.
        handOff.onRestored = { [weak self] identity in
            self?.parkingTabs.remove(identity)
            self?.overlay?.sourceContainmentChanged()
        }
        handOff.onRecoveryRequired = { [weak self] identity in self?.recovery.requestRecovery(for: identity) }
        handOff.onReparked = { [weak self] entry in
            self?.parkingTabs.show(for: entry)
            self?.overlay?.sourceContainmentChanged()
        }
        sourceTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let processID = application.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let active = self.handOff.active,
                      processID == active.identity.processID else { return }
                self.handOff.end(reason: "sourceTerminated")
            }
        }
        // Undo placements left behind by a crash or forced quit before anything else.
        // Entries that cannot be reached yet (another Space, a busy app) are retried.
        recovery.onSettled = { [weak self] identity in
            self?.parkingTabs.remove(identity)
            self?.overlay?.sourceContainmentChanged()
        }
        recovery.start()
        parkingTabs.onRestoreRequest = { [weak self] identity in
            guard let self,
                  let entry = self.placementJournal.entries.first(where: { $0.identity == identity }) else { return }
            let outcome = WindowPlacer.restore(entry, journal: self.placementJournal)
            if !self.placementJournal.entries.contains(where: { $0.identity == identity }) {
                self.parkingTabs.remove(identity)
            }
            if outcome.retriesAutomatically { self.recovery.requestRecovery(for: identity) }
            self.overlay?.sourceContainmentChanged()
            NSLog("Dropy placement: tab clicked restore=%@", PlacementJournal.name(outcome))
        }
        for entry in placementJournal.entries where entry.mode == .parked && entry.applicationConfirmed != false {
            // A hand-off interrupted by a crash usually left the window back on screen,
            // where a tab would cover a window in use. Cover it only while the window
            // server still reports it parked, which needs no Accessibility.
            if entry.handOff != nil, !WindowPlacer.isStillPlaced(entry) { continue }
            parkingTabs.show(for: entry)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◆"
        item.button?.toolTip = "Dropy"
        let menu = NSMenu(title: "Dropy")
        menu.delegate = self
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
        let interactive = NSMenuItem(title: "Interactive preview (beta)", action: #selector(toggleInteractivePreview(_:)),
                                     keyEquivalent: "")
        interactive.state = preferences.value.interactivePreview ? .on : .off
        interactive.toolTip = "Send clicks, scrolling and typing in the preview to the source window, only where verified for that app."
        menu.addItem(interactive)
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
        if let sourceTerminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(sourceTerminationObserver) }
        trigger?.stop()
        hotKey?.unregister()
        recovery.stop()
        // A hand-off is not ended here: re-parking a window as Dropy dies would leave it
        // out of sight with nothing left to restore it. Its journal record is settled by
        // restoreAll() below, which leaves the window where the person is using it.
        // A deferred entry stays in the journal; the next launch keeps trying.
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
            // Only a live preview can show whether a placement keeps capture alive.
            // A paused preview means the source is minimized, hidden or on another Space.
            guard self.overlay.state == .viewing, let identity = self.overlay.currentSelection,
                  let before = self.overlay.captureCounts() else {
                NSLog("Dropy placement: mode=%@ skipped=noLivePreview(%@)", mode.rawValue,
                      self.overlay.state.diagnosticName)
                return
            }
            let entry: PlacementEntry
            do {
                entry = try await WindowPlacer.apply(mode, to: identity, journal: self.placementJournal)
            } catch {
                NSLog("Dropy placement: mode=%@ failed=%@", mode.rawValue, String(describing: error))
                return
            }
            NSLog("Dropy placement applied: window=%u mode=%@", identity.windowID, mode.rawValue)
            try? await Task.sleep(for: .seconds(1))
            let displays = WindowPlacer.displayBounds()
            let server = WindowPlacer.windowServerInfo(identity.windowID)
            // A hidden or minimized window can drop out of the window-server list;
            // not being listed or not on screen both mean nothing is visible.
            var leak = server.map { $0.onScreen ? PlacementGeometry.visibleFraction(of: $0.bounds, on: displays) : 0 } ?? 0
            if mode == .parked, let server {
                // Whatever the tabs cover is out of sight; report only the remainder,
                // counting rectangles that overlap once rather than twice.
                let covered = self.parkingTabs.show(for: entry)
                let area = Double(server.bounds.width * server.bounds.height)
                let onDisplay = PlacementGeometry.visibleArea(of: server.bounds, on: displays)
                let uncovered = PlacementGeometry.uncoveredArea(of: server.bounds, on: displays,
                                                                covered: covered)
                if area > 0 { leak = server.onScreen ? uncovered / area : 0 }
                NSLog("Dropy placement: parked tabs=%ld coveredFraction=%.3f", covered.count,
                      area > 0 ? (onDisplay - uncovered) / area : 0)
            }
            // The tabs are up, so the preview can now tell a hidden source from a
            // visible one and start comparing its frame rate.
            self.overlay.sourceContainmentChanged()
            let placed = self.overlay.captureCounts() ?? before
            try? await Task.sleep(for: .seconds(hold))
            let held = self.overlay.captureCounts() ?? placed
            let stateDuringHold = self.overlay.state.diagnosticName
            // Read before restoring: showing the window again ends the comparison.
            let hiddenSource = self.overlay.hiddenSourceAssessment
            let outcome = WindowPlacer.restore(entry, journal: self.placementJournal)
            if !self.placementJournal.entries.contains(where: { $0.identity == identity }) {
                self.parkingTabs.remove(identity)
            }
            if outcome.retriesAutomatically { self.recovery.requestRecovery(for: identity) }
            self.overlay.sourceContainmentChanged()
            try? await Task.sleep(for: .milliseconds(500))
            let restored = try? WindowPlacer.state(of: identity)
            let verified = restored.map { $0.approximatelyEquals(entry.original) }
            NSLog("Dropy placement: mode=%@ placedFrameLeak=%.3f windowServerLeak=%@ windowOnScreen=%@ overlay=%@ capture=%@ restore=%@ verified=%@ hiddenSource=%@",
                  mode.rawValue,
                  entry.applied.isMinimized || entry.applied.isAppHidden
                      ? 0 : PlacementGeometry.visibleFraction(of: entry.applied.frame, on: displays),
                  String(format: "%.3f", leak),
                  server.map { $0.onScreen ? "yes" : "no" } ?? "notListed",
                  stateDuringHold, held.delta(since: placed),
                  PlacementJournal.name(outcome),
                  verified.map { $0 ? "yes" : "no" } ?? "unknown",
                  hiddenSource.diagnosticName)
        }
    }

    @objc private func recoverPlacements() {
        if placementJournal.loadError != nil {
            let alert = NSAlert()
            alert.messageText = "Window recovery journal could not be read"
            alert.informativeText = "The original records are preserved at \(placementJournal.quarantineURL?.path ?? PlacementJournal.defaultURL.path). Valid records can still be recovered. New placements remain blocked while damaged records need attention."
            alert.runModal()
            guard placementJournal.canRecover else { return }
        }
        recovery.recoverAll()
        // An interrupted hand-off is not an ambiguous move: its record says where the
        // window belongs, so it needs no question and gets none.
        for entry in placementJournal.entries where entry.applicationConfirmed == false && entry.handOff == nil {
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
        recovery.recoverAll()
        overlay?.sourceContainmentChanged()
        let waiting = recovery.deferred
        if !waiting.isEmpty {
            let alert = NSAlert()
            alert.messageText = waiting.count == 1 ? "A window is still waiting to be restored"
                : "\(waiting.count) windows are still waiting to be restored"
            let apps = waiting.map { NSRunningApplication(processIdentifier: $0.entry.identity.processID)?
                .localizedName ?? "An app" }
            let advice = Set(waiting.map(\.reason.advice)).sorted()
            alert.informativeText = (Set(apps).sorted().joined(separator: ", ") + ". " + advice.joined(separator: " "))
            alert.runModal()
        } else if placementJournal.entries.isEmpty {
            parkingTabs.removeAll()
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

    @objc private func toggleInteractivePreview(_ sender: NSMenuItem) {
        let enabled = !preferences.value.interactivePreview
        preferences.update { $0.interactivePreview = enabled }
        sender.state = enabled ? .on : .off
        // Input to another app needs Accessibility; ask macOS to show its prompt once.
        if enabled, !WindowPlacer.isTrusted {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        overlay.configureInteraction()
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
