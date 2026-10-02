import AppKit
import DropyCore

/// Opens the overlay from the notch while costing nothing the rest of the time.
///
/// On a screen with a camera housing, a transparent panel sits over the notch, which
/// is dead space with no menu items, plus the thin edges the pointer can actually
/// reach (macOS keeps it out of the notch itself). Its tracking area wakes Dropy
/// only when the pointer enters it. Screens without a notch fall back to global
/// mouse-move and click monitors, because an invisible window in the menu bar
/// there could sit on top of real menu items; those monitors are installed only
/// while such a screen is connected.
@MainActor
final class NotchTrigger {
    private let mode: () -> Trigger
    private let isArmed: () -> Bool
    private let open: () -> Void
    private var panels: [NotchPanel] = []
    private var monitors: [Any] = []
    private var pendingHover: DispatchWorkItem?
    /// After a close the notch stays quiet for a moment and until the pointer has
    /// left the zone, so a close cannot turn straight into another opening.
    private var quietUntil = Date.distantPast
    private var waitingForExit = false
    private var screenObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - mode: the current trigger preference.
    ///   - isArmed: whether a trigger may open the overlay now (it is closed).
    init(mode: @escaping () -> Trigger, isArmed: @escaping () -> Bool, open: @escaping () -> Void) {
        self.mode = mode
        self.isArmed = isArmed
        self.open = open
    }

    func start() {
        rebuild()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        tearDown()
    }

    private func tearDown() {
        cancelHover()
        panels.forEach { $0.orderOut(nil) }
        panels = []
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func rebuild() {
        tearDown()
        var needsMonitors = false
        for screen in NSScreen.screens {
            guard let zone = Self.notchZone(on: screen) else {
                needsMonitors = true
                continue
            }
            let panel = NotchPanel(frame: zone)
            panel.onEnter = { [weak self] in self?.pointerEntered(zone) }
            panel.onExit = { [weak self] in self?.pointerLeftZone() }
            panel.onClick = { [weak self] in self?.clicked() }
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        if needsMonitors { installFallbackMonitors() }
        NSLog("Dropy trigger: notchPanels=%ld fallbackMonitors=%@", panels.count,
              needsMonitors ? "yes" : "no")
    }

    /// Where the pointer can reach at the notch, in screen coordinates, or nil for a
    /// screen without one. The pointer cannot enter the notch itself, so the zone
    /// also covers a thin band below it and beside it.
    static func notchZone(on screen: NSScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        let notch = CGRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                           width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        return OverlayGeometry.notchReach(notch)
    }

    /// The overlay closed: keep the notch quiet until the pointer has left it.
    func overlayClosed() {
        cancelHover()
        quietUntil = Date().addingTimeInterval(HoverIntent.rearmDelay)
        waitingForExit = true
    }

    /// Opens after the hover delay only if the pointer rested there rather than
    /// passing through (HoverIntent).
    private func pointerEntered(_ zone: CGRect) {
        guard mode() == .notchHover, isArmed(), pendingHover == nil,
              !waitingForExit, Date() >= quietUntil else { return }
        let entry = NSEvent.mouseLocation
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingHover = nil
            guard self.mode() == .notchHover, self.isArmed(),
                  HoverIntent.confirms(enteredAt: entry, now: NSEvent.mouseLocation, zone: zone) else { return }
            self.open()
        }
        pendingHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverIntent.delay, execute: work)
    }

    private func pointerLeftZone() {
        cancelHover()
        waitingForExit = false
    }

    private func cancelHover() {
        pendingHover?.cancel()
        pendingHover = nil
    }

    private func clicked() {
        guard mode() == .notchClick, isArmed(), Date() >= quietUntil else { return }
        open()
    }

    // MARK: Fallback for screens without a notch

    private func installFallbackMonitors() {
        let move: (NSEvent) -> Void = { [weak self] _ in self?.fallbackPointerMoved() }
        let click: (NSEvent) -> Void = { [weak self] _ in self?.fallbackClicked() }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: move) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: click) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: {
            move($0)
            return $0
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: {
            click($0)
            return $0
        }) { monitors.append(monitor) }
    }

    /// The center band of the menu bar on a screen without a notch.
    private func fallbackZone() -> CGRect? {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }),
              Self.notchZone(on: screen) == nil else { return nil }
        return OverlayGeometry.notchTrigger(on: screen.frame, notchWidth: 208,
                                            bandHeight: max(screen.safeAreaInsets.top, 38))
    }

    private func fallbackPointerMoved() {
        guard mode() == .notchHover, isArmed(), let zone = fallbackZone(),
              zone.contains(NSEvent.mouseLocation) else {
            pointerLeftZone()
            return
        }
        pointerEntered(zone)
    }

    private func fallbackClicked() {
        guard let zone = fallbackZone(), zone.contains(NSEvent.mouseLocation) else { return }
        clicked()
    }
}

/// A transparent, non-activating panel over the notch and its edges that reports pointer entry,
/// exit and clicks. It never takes focus and joins every Space.
private final class NotchPanel: NSPanel {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClick: (() -> Void)?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        let view = TrackingView(frame: CGRect(origin: .zero, size: frame.size))
        view.panel = self
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class TrackingView: NSView {
        weak var panel: NotchPanel?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { panel?.onEnter?() }
        override func mouseExited(with event: NSEvent) { panel?.onExit?() }
        override func mouseDown(with event: NSEvent) { panel?.onClick?() }
        // Accept the first click even though the panel never becomes key.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
