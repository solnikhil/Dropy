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
    private let placementJournal = PlacementJournal()
    private let parkingTabs = ParkingTabs()
    /// The hidden display where pinned apps wait between openings.
    private let stage: Stage? = Stage.isSupported ? Stage() : nil
    private lazy var recovery = PlacementRecovery(journal: placementJournal)
    /// The person's animation files, watched for changes.
    let animations = AnimationLibrary()
    /// Plays an animation on the notch for the Studio and `Dropy animation play`.
    private let demo = AnimationDemo()
    private lazy var studio = AnimationStudioController(library: animations)
    private var settings: SettingsWindowController!
    /// Submenus whose check marks mirror a preference, refreshed whenever one changes.
    private var choiceMenus: [(menu: NSMenu, selected: (DropyPreferences) -> String)] = []
    private var fullAppItems: [NSMenuItem] = []
    private var animationMenu: NSMenu?
    /// "Open Dropy" items whose titles show the current shortcut.
    private var openItems: [NSMenuItem] = []
    /// Check scripts launch the binary with debug variables or --show; they keep the
    /// menu-bar-only policy their focus and timing measurements were taken with.
    private static let launchedByCheck = CommandLine.arguments.contains("--show")
        || ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("DROPY_DEBUG_") }

    static func main() {
        // `Dropy animation …`: the animation tools for the terminal and AI agents.
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "animation" {
            exit(AnimationCommand.run(Array(CommandLine.arguments.dropFirst(2))))
        }
        let app = NSApplication.shared
        let delegate = DropyAppDelegate()
        app.delegate = delegate
        // Info.plist starts Dropy as a menu-bar app, so no Dock icon flashes when
        // "Show in Dock" is off; the policy is set before the first event.
        app.setActivationPolicy(delegate.wantsDockIcon ? .regular : .accessory)
        app.run()
    }

    /// Status menus can be tracked by the system without an NSEvent reaching our
    /// local/global monitors. Opening this menu is an outside interaction regardless
    /// of which process owns its mouse event; the dismissal preference decides.
    func menuWillOpen(_ menu: NSMenu) {
        overlay?.dismiss(.clickOutside)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        animations.start()
        animations.onChange = { [weak self] in self?.applyAnimation() }
        applyAnimation()
        listenForAnimationRequests()
        overlay = OverlayController(preferences: preferences, journal: placementJournal, stage: stage)
        stage?.onLost = { [weak self] in self?.overlay.stageLost() }
        overlay.onDeferredRestore = { [weak self] identity in self?.recovery.requestRecovery(for: identity) }
        // Undo placements left behind by a crash or forced quit before anything else.
        // Entries that cannot be reached yet (another Space, a busy app) are retried.
        recovery.onSettled = { [weak self] identity in
            self?.parkingTabs.remove(identity)
            self?.overlay.journalChanged()
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
            self.overlay.journalChanged()
            NSLog("Dropy placement: tab clicked restore=%@", PlacementJournal.name(outcome))
        }
        for entry in placementJournal.entries where entry.mode == .parked && entry.applicationConfirmed != false {
            parkingTabs.show(for: entry)
        }
        settings = SettingsWindowController(model: SettingsModel(
            preferences: preferences.value, change: { [weak self] edit in self?.change(edit) }))
        settings.onVisibilityChange = { [weak self] in self?.updateActivationPolicy() }
        settings.model.animations = animations
        settings.model.playOnNotch = { [weak self] animation, slowdown in self?.playOnNotch(animation, slowdown: slowdown) ?? 0 }
        settings.model.openStudio = { [weak self] id in self?.studio.open(id) }
        studio.playOnNotch = { [weak self] animation, slowdown in self?.playOnNotch(animation, slowdown: slowdown) ?? 0 }
        studio.use = { [weak self] id in self?.change { $0.customAnimation = id } }
        studio.inUse = { [weak self] id in
            guard let self else { return false }
            return self.preferences.value.customAnimation == id && self.animations.choice(for: self.preferences.value).problem == nil
        }
        studio.onVisibilityChange = { [weak self] in self?.updateActivationPolicy() }
        applyAnimation()
        NSApp.mainMenu = makeMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◆"
        item.button?.toolTip = "Dropy"
        let menu = NSMenu(title: "Dropy")
        menu.delegate = self
        openItems.append(addOverlayItems(to: menu))
        menu.addItem(.separator())
        let triggers = NSMenu(title: "Notch trigger")
        for trigger in Trigger.allCases {
            let title = switch trigger {
            case .notchHover: "Hover"
            case .notchClick: "Click"
            case .shortcut: "Shortcut only"
            }
            // Without an action the menu shows the choice greyed out while paused.
            let entry = NSMenuItem(title: title, action: Trigger.notchPaused ? nil : #selector(changeTrigger(_:)),
                                   keyEquivalent: "")
            entry.representedObject = trigger.rawValue
            entry.state = preferences.value.trigger == trigger ? .on : .off
            triggers.addItem(entry)
        }
        let triggerItem = NSMenuItem(title: Trigger.notchPaused ? "Notch trigger (paused)" : "Notch trigger",
                                     action: nil, keyEquivalent: "")
        triggerItem.submenu = triggers
        menu.addItem(triggerItem)
        choiceMenus.append((triggers, { $0.trigger.rawValue }))
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
        choiceMenus.append((dismissals, { $0.dismissBehavior.rawValue }))
        let sizes = NSMenu(title: "Overlay size")
        for preset in SizePreset.allCases {
            let entry = NSMenuItem(title: preset.title,
                                   action: #selector(changeSize(_:)), keyEquivalent: "")
            entry.representedObject = preset.rawValue
            entry.state = preferences.value.sizePreset == preset ? .on : .off
            sizes.addItem(entry)
        }
        let sizeItem = NSMenuItem(title: "Overlay size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)
        choiceMenus.append((sizes, { $0.sizePreset.rawValue }))
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
        choiceMenus.append((openModes, { $0.openBehavior.rawValue }))
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
        choiceMenus.append((contentModes, { $0.contentMode.rawValue }))
        // Filled each time it opens (menuNeedsUpdate), since animation files come and go.
        let animationMenu = NSMenu(title: "Animation")
        animationMenu.delegate = self
        self.animationMenu = animationMenu
        let animationItem = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
        animationItem.submenu = animationMenu
        menu.addItem(animationItem)
        let fullApp = NSMenuItem(title: "Use Apps in the Overlay", action: #selector(toggleFullApp(_:)),
                                 keyEquivalent: "")
        fullApp.state = preferences.value.interaction == .fullApp ? .on : .off
        fullApp.toolTip = "Bring the app's real window into the overlay. Off shows a live preview only."
        menu.addItem(fullApp)
        fullAppItems.append(fullApp)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Dropy", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items { if entry.action != nil { entry.target = self } }
        for entry in sizes.items { entry.target = self }
        for entry in openModes.items { entry.target = self }
        for entry in triggers.items { entry.target = self }
        for entry in contentModes.items { entry.target = self }
        item.menu = menu
        statusItem = item
        registerShortcut()

        let trigger = NotchTrigger(mode: { [weak self] in self?.preferences.value.trigger.effective ?? .shortcut },
                                   isArmed: { [weak self] in self?.overlay.state == .closed },
                                   restrictCrossing: { [weak self] in self?.preferences.value.restrictNotchCrossing ?? false },
                                   open: { [weak self] in
                                       // A light tap on a Force Touch trackpad as the notch
                                       // gives way, like the system's own snap feedback.
                                       NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                                       self?.overlay.open()
                                   })
        trigger.onRestrictionStatus = { [weak self] message in self?.settings.model.cursorRestrictionStatus = message }
        trigger.start()
        self.trigger = trigger
        overlay.onOpen = { [weak trigger] in trigger?.overlayOpened() }
        overlay.onClose = { [weak trigger] in trigger?.overlayClosed() }
        if wantsDockIcon { NSApp.activate(ignoringOtherApps: true) }
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.async { [weak self] in self?.overlay.open() }
        }
        // Development: `--settings <page>` opens Settings on that page; `--studio <name>`
        // opens an animation file in the Animation Studio.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--settings") {
            if index + 1 < arguments.count, let pane = SettingsPane(rawValue: arguments[index + 1]) {
                settings.model.navigate(to: pane)
            }
            settings.show()
        }
        if let index = arguments.firstIndex(of: "--studio"), index + 1 < arguments.count {
            studio.open(arguments[index + 1])
        }
        startStageIfUseful()
        startDebugDriversIfRequested()
    }

    /// The Stage is created ahead of the first opening, so pinned apps open at once. It
    /// needs Full App interaction and Accessibility; it is never created otherwise.
    private func startStageIfUseful() {
        startStageRetirement()
        guard let stage, keepsStage, WindowPlacer.isTrusted else { return }
        Task { await stage.start() }
    }

    /// Keep the Stage between openings: only for a pinned app kept ready.
    private var keepsStage: Bool {
        let value = preferences.value
        return value.interaction == .fullApp && value.keepsPinnedAppReady && value.pinnedBundleIdentifier != nil
    }

    private var stageRetirement: Timer?
    private var stageIdleSince: Date?

    /// macOS treats the Stage as a real display, so a full-screen screenshot (⇧⌘3)
    /// saves a black picture of it as well. Unless a pinned app is kept ready there, the
    /// Stage is created only when an opening needs it (Live mode, or a window from another
    /// desktop) and removed once Dropy has been closed a few seconds with nothing on it.
    private func startStageRetirement() {
        guard stageRetirement == nil, stage != nil else { return }
        stageRetirement = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retireStageIfIdle() }
        }
    }

    private func retireStageIfIdle() {
        guard let stage, stage.isReady, !keepsStage, !overlay.needsStage, !stage.isOccupied else {
            stageIdleSince = nil
            return
        }
        let since = stageIdleSince ?? Date()
        stageIdleSince = since
        guard Date().timeIntervalSince(since) >= 6 else { return }
        stageIdleSince = nil
        NSLog("Dropy stage: removed after being unused (it is created again when needed)")
        stage.stop()
    }

    /// Development-only drivers for repeatable measurements without input automation.
    /// - `DROPY_DEBUG_CYCLES=<n>[,<hold-ms>]`: open, wait for a live preview (or a failure,
    ///   up to ten seconds), hold, close; repeat n times.
    /// - `DROPY_DEBUG_LIVE_POINTER=1`: with the cycles, once Live mode is up, move the
    ///   pointer into the app and click it, as a person would, and log whether the overlay
    ///   stayed open (it must) and the pointer came back off the Stage afterwards.
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
                    while self.overlay.state != .viewing, self.overlay.state != .docked, self.overlay.state != .live,
                          self.overlay.state.failure == nil, waited < 10_000 {
                        try? await Task.sleep(for: .milliseconds(50))
                        waited += 50
                    }
                    NSLog("Dropy debug cycle %ld: %@", cycle, self.overlay.state.diagnosticName)
                    if environment["DROPY_DEBUG_LIVE_POINTER"] != nil, self.overlay.state == .live {
                        await self.exerciseLivePointer()
                    }
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
        // An edit made in the Animation Studio a moment ago is saved, not lost.
        studio.model?.saveNow()
        demo.stop()
        overlay.shutdown()
        trigger?.stop()
        hotKey?.unregister()
        recovery.stop()
        // A deferred entry stays in the journal; the next launch keeps trying.
        placementJournal.restoreAll()
        parkingTabs.removeAll()
        // Last: windows on the Stage have been put back by now; wait for the moves to land.
        stage?.waitUntilEmpty()
        stage?.stop()
    }

    /// Development-only M2 experiment:
    /// `DROPY_DEBUG_PLACEMENT=<offscreen|minimize|hideApp|parked>[,<hold-seconds>]`. Once a
    /// preview is live, place the source window, hold, restore, and log capture
    /// continuity, how much of the window stayed visible, and whether the restore
    /// matched the original. Logs modes, counts and fractions only.
    /// Moves the pointer into the cast in small steps, clicks, and moves it back out,
    /// through the HID event path a mouse uses (so the Stage's tap sees it).
    private func exerciseLivePointer() async {
        guard let cast = overlay.liveCast else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        // A mouse reports motion from wherever the pointer is, which after the hand-off
        // is on the Stage, so each step goes from the current location.
        func move(_ from: CGPoint, _ to: CGPoint) async {
            let steps = 12
            let delta = CGPoint(x: (to.x - from.x) / CGFloat(steps), y: (to.y - from.y) / CGFloat(steps))
            for _ in 0..<steps {
                let current = CGEvent(source: nil)?.location ?? from
                let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                    mouseCursorPosition: CGPoint(x: current.x + delta.x, y: current.y + delta.y),
                                    mouseButton: .left)
                event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
                event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
                event?.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        let outside = CGPoint(x: cast.midX, y: cast.maxY + 80)
        let inside = CGPoint(x: cast.midX, y: cast.midY)
        CGWarpMouseCursorPosition(outside)
        CGAssociateMouseAndMouseCursorPosition(1)
        try? await Task.sleep(for: .milliseconds(100))
        await move(outside, inside)
        try? await Task.sleep(for: .milliseconds(500))
        let onStage = CGEvent(source: nil)?.location ?? .zero
        let handedOver = !Stage.realDisplays(excluding: stage?.displayID).contains { $0.contains(onStage) }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: onStage, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .milliseconds(800))
        let keptAfterClick = overlay.state == .live
        await move(inside, outside)
        try? await Task.sleep(for: .milliseconds(300))
        let back = CGEvent(source: nil)?.location ?? .zero
        let returned = Stage.realDisplays(excluding: stage?.displayID).contains { $0.contains(back) }
        NSLog("Dropy debug live pointer: handedOver=%@ kept=%@ returned=%@ state=%@",
              handedOver ? "yes" : "no", keptAfterClick ? "yes" : "no", returned ? "yes" : "no",
              overlay.state.diagnosticName)
    }

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
            let outcome = WindowPlacer.restore(entry, journal: self.placementJournal)
            if !self.placementJournal.entries.contains(where: { $0.identity == identity }) {
                self.parkingTabs.remove(identity)
            }
            if outcome.retriesAutomatically { self.recovery.requestRecovery(for: identity) }
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
                  PlacementJournal.name(outcome),
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
        recovery.recoverAll()
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
        recovery.recoverAll()
        overlay.journalChanged()
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
    @objc private func quit() { overlay.shutdown(); NSApp.terminate(nil) }
    @objc private func showSettings() { settings.show() }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Your apps, near the notch.\nFree and MIT-licensed.")
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openProjectPage() {
        if let url = URL(string: "https://github.com/solnikhil/Dropy") { NSWorkspace.shared.open(url) }
    }

    @objc private func changeSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let size = SizePreset(rawValue: raw) else { return }
        change { $0.sizePreset = size }
    }

    @objc private func changeTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let trigger = Trigger(rawValue: raw) else { return }
        change { $0.trigger = trigger }
    }

    @objc private func changeDismissBehavior(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let behavior = DismissBehavior(rawValue: raw) else { return }
        change { $0.dismissBehavior = behavior }
    }

    @objc private func changeContentMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ContentMode(rawValue: raw) else { return }
        change { $0.contentMode = mode }
    }

    @objc private func toggleFullApp(_ sender: NSMenuItem) {
        change { $0.interaction = $0.interaction == .fullApp ? .previewOnly : .fullApp }
    }

    @objc private func changeOpenBehavior(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = OpenBehavior(rawValue: raw) else { return }
        change { $0.openBehavior = mode }
    }

    /// The one place preferences change, from a menu or the Settings window.
    private func change(_ edit: (inout DropyPreferences) -> Void) {
        let old = preferences.value
        preferences.update(edit)
        let new = preferences.value
        guard new != old else { return }
        if new.trigger != old.trigger || new.restrictNotchCrossing != old.restrictNotchCrossing {
            if new.restrictNotchCrossing, !WindowPlacer.isTrusted {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            trigger?.preferencesChanged()
        }
        if new.interaction != old.interaction {
            // Moving another app's window needs Accessibility; ask macOS to show its prompt once.
            if new.interaction == .fullApp, !WindowPlacer.isTrusted {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
        }
        if new.interaction != old.interaction {
            overlay.dockingPreferencesChanged()
            startStageIfUseful()
        }
        if new.sizePreset != old.sizePreset || new.contentMode != old.contentMode || new.automaticWindowSize != old.automaticWindowSize, overlay.state != .closed {
            overlay.close()
            overlay.open()
        }
        if new.showInDock != old.showInDock { updateActivationPolicy() }
        // The next motion uses the new animation; one already playing finishes as it began.
        if new.motionStyle != old.motionStyle || new.customAnimation != old.customAnimation { applyAnimation() }
        if new.shortcut != old.shortcut, !registerShortcut() {
            // Another app owns it: keep the shortcut that works and say why.
            preferences.update { $0.shortcut = old.shortcut }
            registerShortcut()
            settings.model.shortcutRejected("Another app already uses \(new.shortcut.display). Choose a different one.")
        }
        if new.keepsPinnedAppReady != old.keepsPinnedAppReady {
            overlay.pinnedAppChanged()
            startStageIfUseful()
        }
        if new.pinnedBundleIdentifier != old.pinnedBundleIdentifier {
            overlay.pinnedAppChanged()
            startStageIfUseful()
            // An open overlay still choosing a window shows the newly pinned app now.
            if new.pinnedBundleIdentifier != nil, overlay.state == .selecting { overlay.refreshWindows() }
        }
        syncMenuChecks()
        settings.model.preferencesChanged(preferences.value)
    }

    // MARK: Animations

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === animationMenu else { return }
        menu.removeAllItems()
        let current = preferences.value
        func add(_ title: String, _ action: Selector?, _ value: String? = nil, on: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        for style in MotionStyle.allCases {
            add(style.title, #selector(chooseBuiltInAnimation(_:)), style.rawValue,
                on: current.customAnimation == nil && current.motionStyle == style)
        }
        let usable = animations.entries.filter { $0.animation != nil }
        if !usable.isEmpty {
            menu.addItem(.separator())
            for entry in usable {
                add(entry.name, #selector(chooseCustomAnimation(_:)), entry.id, on: current.customAnimation == entry.id)
            }
        }
        menu.addItem(.separator())
        add("Play on Notch", #selector(playCurrentAnimation))
        add("Animation Settings…", #selector(showAnimationSettings))
    }

    @objc private func chooseBuiltInAnimation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = MotionStyle(rawValue: raw) else { return }
        change { $0.motionStyle = style; $0.customAnimation = nil }
    }

    @objc private func chooseCustomAnimation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        change { $0.customAnimation = id }
    }

    @objc private func playCurrentAnimation() { playOnNotch(OverlayMotion.animation, slowdown: 1) }

    @objc private func showAnimationSettings() {
        settings.model.navigate(to: .animation)
        settings.show()
    }

    /// `DROPY_ANIMATION=<file>` (development, benchmarks): use this file whatever the
    /// preferences say.
    private static let animationOverride: DropyAnimation? = {
        guard let path = ProcessInfo.processInfo.environment["DROPY_ANIMATION"] else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let result = AnimationLibrary.read(url)
        for issue in result.issues { NSLog("Dropy animation: %@", issue.description) }
        return result.animation
    }()

    /// Puts the chosen animation (or the built-in style, when the chosen file cannot be
    /// used) in charge of the overlay's motion.
    private func applyAnimation() {
        let choice = animations.choice(for: preferences.value)
        OverlayMotion.animation = Self.animationOverride ?? choice.animation
        settings?.model.animationChanged(choice)
        if let problem = choice.problem { NSLog("Dropy animation: %@", problem) }
    }

    /// Plays an animation on the notch, closing the overlay first if it is open.
    @discardableResult
    func playOnNotch(_ animation: DropyAnimation, slowdown: Double) -> TimeInterval {
        guard let slowdown = AnimationPlayback.slowdown(slowdown) else { return 0 }
        let position = overlay.preferences.value.position
        guard overlay.state != .closed else { return demo.play(animation, slowdown: slowdown, at: position) }
        overlay.close()
        let wait = OverlayMotion.wall(OverlayMotion.morph.close.duration) + 0.1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            self?.demo.play(animation, slowdown: slowdown, at: position)
        }
        return wait + (animation.morph.open.duration + animation.morph.resize.duration + animation.morph.close.duration
                       + AnimationDemo.holdOpen + AnimationDemo.holdResized) * slowdown
    }

    /// Requests from `Dropy animation play` and `use` in a terminal.
    private func listenForAnimationRequests() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(remotePlay(_:)),
                           name: Notification.Name(AnimationRemote.Request.play.rawValue), object: nil,
                           suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(remoteUse(_:)),
                           name: Notification.Name(AnimationRemote.Request.use.rawValue), object: nil,
                           suspensionBehavior: .deliverImmediately)
    }

    @objc private func remotePlay(_ note: Notification) {
        guard let id = note.object as? String, let code = note.userInfo?["payload"] as? String else { return }
        let slow = (note.userInfo?["slow"] as? NSNumber)?.doubleValue ?? 1
        guard let slow = AnimationPlayback.slowdown(slow) else {
            return AnimationRemote.answer(id, "Slowdown must be a finite number.")
        }
        guard let animation = AnimationFile.read(shareCode: code).animation else {
            return AnimationRemote.answer(id, "Dropy could not read that animation.")
        }
        let seconds = playOnNotch(animation, slowdown: slow)
        AnimationRemote.answer(id, String(format: "Playing “%@” on the notch for %.1f s: it opens, resizes, then closes%@.",
                                          animation.name, seconds, slow > 1 ? String(format: ", %.0f× slower", slow) : ""))
    }

    @objc private func remoteUse(_ note: Notification) {
        guard let id = note.object as? String, let target = note.userInfo?["payload"] as? String else { return }
        animations.scan()
        if let style = MotionStyle(rawValue: target) {
            change { $0.motionStyle = style; $0.customAnimation = nil }
        } else if animations.entry(target)?.animation != nil {
            change { $0.customAnimation = target }
        } else {
            // Any process on the Mac can send this request: only a usable file in the
            // animations folder may become the preference.
            return AnimationRemote.answer(id, "There is no usable animation called “\(AnimationText.clean(target, limit: 60))”.")
        }
        let choice = animations.choice(for: preferences.value)
        AnimationRemote.answer(id, choice.problem ?? "Dropy now uses “\(choice.animation.name)”.")
    }

    /// Registers the shortcut from preferences in place of the current one; false when
    /// another app owns it. Menu titles show it only while it works.
    @discardableResult
    private func registerShortcut() -> Bool {
        hotKey?.unregister()
        let shortcut = preferences.value.shortcut
        hotKey = GlobalHotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.overlay.toggle()
        }
        for item in openItems { item.title = openTitle }
        settings.model.shortcutRegistered = hotKey != nil
        return hotKey != nil
    }

    private var openTitle: String {
        hotKey == nil ? "Open Dropy" : "Open Dropy (\(preferences.value.shortcut.display))"
    }

    private func syncMenuChecks() {
        for (menu, selected) in choiceMenus {
            let raw = selected(preferences.value)
            for item in menu.items { item.state = item.representedObject as? String == raw ? .on : .off }
        }
        for item in fullAppItems { item.state = preferences.value.interaction == .fullApp ? .on : .off }
    }

    // MARK: Ordinary-app behavior

    private var wantsDockIcon: Bool { preferences.value.showInDock && !Self.launchedByCheck }

    /// A Dock icon and Dropy's own menu bar when "Show in Dock" is on, and always while
    /// Settings is open so the window can be found with Command-Tab.
    private func updateActivationPolicy() {
        let regular = wantsDockIcon || settings.isVisible || studio.isVisible
        guard NSApp.activationPolicy() != (regular ? .regular : .accessory) else { return }
        NSApp.setActivationPolicy(regular ? .regular : .accessory)
        if regular { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Opening Dropy again from Finder, Spotlight or the Dock shows Settings, the way an
    /// ordinary app shows its main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if overlay.state == .closed { settings.show() }
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        addOverlayItems(to: menu)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        return menu
    }

    /// Adds Open, Refresh and Recover; returns the Open item.
    @discardableResult
    private func addOverlayItems(to menu: NSMenu) -> NSMenuItem {
        let open = NSMenuItem(title: openTitle, action: #selector(toggleOverlay), keyEquivalent: "")
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Refresh windows", action: #selector(refresh), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Recover pending source windows…",
                                action: #selector(recoverPlacements), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        return open
    }

    /// The menu bar shown while Dropy is the active app.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }

        _ = submenu("Dropy", [
            item("About Dropy", #selector(showAbout), target: self),
            .separator(),
            item("Settings…", #selector(showSettings), ",", target: self),
            .separator(),
            item("Hide Dropy", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp),
            .separator(),
            item("Quit Dropy", #selector(quit), "q", target: self),
        ])

        let overlayMenu = NSMenu(title: "Overlay")
        openItems.append(addOverlayItems(to: overlayMenu))
        overlayMenu.addItem(.separator())
        let fullApp = item("Use Apps in the Overlay", #selector(toggleFullApp(_:)), target: self)
        overlayMenu.addItem(fullApp)
        fullAppItems.append(fullApp)
        let overlayHolder = NSMenuItem(title: "Overlay", action: nil, keyEquivalent: "")
        overlayHolder.submenu = overlayMenu
        main.addItem(overlayHolder)

        let window = submenu("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp),
        ])
        NSApp.windowsMenu = window

        let help = submenu("Help", [item("Dropy on GitHub", #selector(openProjectPage), target: self)])
        NSApp.helpMenu = help
        return main
    }
}
