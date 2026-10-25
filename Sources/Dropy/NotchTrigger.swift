import AppKit
import DropyCore

/// Three reachable edges share one hover session. Passive mouse observation works
/// across the menu bar without invisible windows intercepting other applications.
@MainActor
final class NotchTrigger {
    private let mode: () -> Trigger
    private let isArmed: () -> Bool
    private let restrictCrossing: () -> Bool
    private let open: () -> Void
    private var activations: [NotchActivation] = []
    private var monitors: [EventMonitor] = []
    private var scheduledDeadline: TimeInterval?
    private var pendingHover: DispatchWorkItem?
    private var timerGeneration = UUID()
    private var hover = NotchHoverSession()
    private var activeScreen: Int?
    private var quietUntil: TimeInterval = 0
    private var screenObserver: NotificationObservation?
    private var activeObserver: NotificationObservation?
    var onRestrictionStatus: ((String) -> Void)?
    private lazy var restriction = NotchCursorRestriction(isArmed: { [weak self] in
        guard let self else { return false }
        return self.isArmed() && self.mode() != .shortcut
    })
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(mode: @escaping () -> Trigger, isArmed: @escaping () -> Bool,
         restrictCrossing: @escaping () -> Bool = { false }, open: @escaping () -> Void) {
        self.mode = mode; self.isArmed = isArmed; self.restrictCrossing = restrictCrossing; self.open = open
    }
    func start() {
        guard screenObserver == nil, activeObserver == nil else { return }
        restriction.onStatus = { [weak self] message in self?.onRestrictionStatus?(message) }
        rebuild()
        activeObserver = NotificationObservation(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isArmed() else { return }
                    self.configureRestriction()
                }
            }
        screenObserver = NotificationObservation(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.rebuild() } }
    }
    func stop() {
        activeObserver = nil
        screenObserver = nil; tearDown()
    }
    func preferencesChanged() { rebuild() }
    func overlayOpened() {
        cancelHover(); stopObservation(); hover.reset(); activeScreen = nil
        restriction.stop()
    }
    func overlayClosed() {
        cancelHover()
        let inside = target(at: NSEvent.mouseLocation) != nil
        quietUntil = now + HoverIntent.rearmDelay
        hover.closed(at: now, pointerInside: inside)
        installMouseObservation()
        configureRestriction()
    }
    private func tearDown() {
        cancelHover(); stopObservation(); hover = NotchHoverSession(); activeScreen = nil
        restriction.stop(); activations = []
    }
    private func rebuild() {
        tearDown()
        activations = NSScreen.screens.compactMap { Self.housing(on: $0).map(NotchActivation.init) }
        if isArmed() { installMouseObservation(); configureRestriction() }
    }
    private func stopObservation() {
        monitors = []
    }
    static func housing(on screen: NSScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX, screen.safeAreaInsets.top > 0 else { return nil }
        return CGRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                      width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    }
    private func configureRestriction() {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let housings = activations.map { a in
            CGRect(x: a.housing.minX, y: top - a.housing.maxY, width: a.housing.width, height: a.housing.height)
        }
        let screens = NSScreen.screens.filter { Self.housing(on: $0) != nil }.map { screen in
            CGRect(x: screen.frame.minX, y: top - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        }
        restriction.configure(enabled: restrictCrossing() && mode() != .shortcut, housings: housings, screens: screens)
    }
    private func target(at point: CGPoint) -> (screen: Int, region: NotchActivation.Region)? {
        for (index, activation) in activations.enumerated() {
            if let region = activation.region(at: point) { return (index, region) }
        }
        for (index, screen) in NSScreen.screens.enumerated() where Self.housing(on: screen) == nil {
            let zone = OverlayGeometry.notchTrigger(on: screen.frame, notchWidth: 208, bandHeight: 38)
            if zone.contains(point) { return (activations.count + index, .base) }
        }
        return nil
    }
    private func pointerMoved() {
        guard isArmed(), mode() == .notchHover else { cancelHover(); hover.reset(); return }
        let point = NSEvent.mouseLocation
        let target = target(at: point)
        if let target, activeScreen != target.screen { hover.reset(); activeScreen = target.screen }
        if hover.sample(point: point, region: target?.region, at: now) { cancelHover(); open(); return }
        guard let deadline = hover.deadline else { cancelHover(); return }
        guard scheduledDeadline != deadline else { return }
        cancelHover()
        scheduledDeadline = deadline
        let generation = timerGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.timerGeneration == generation else { return }
            self.pendingHover = nil; self.scheduledDeadline = nil
            self.pointerMoved()
        }
        pendingHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, deadline - now), execute: work)
    }
    private func cancelHover() { timerGeneration = UUID(); pendingHover?.cancel(); pendingHover = nil; scheduledDeadline = nil }
    private func clicked() {
        guard mode() != .shortcut, isArmed(), now >= quietUntil, target(at: NSEvent.mouseLocation) != nil else { return }
        cancelHover(); open()
    }
    private func installMouseObservation() {
        stopObservation()
        guard isArmed(), mode() != .shortcut else { return }
        let move: @MainActor (NSEvent) -> Void = { [weak self] _ in self?.pointerMoved() }
        let click: @MainActor (NSEvent) -> Void = { [weak self] _ in self?.clicked() }
        if let m = EventMonitor.global(matching: .mouseMoved, handler: move) { monitors.append(m) }
        if let m = EventMonitor.global(matching: .leftMouseDown, handler: click) { monitors.append(m) }
        if let m = EventMonitor.local(matching: .mouseMoved, handler: { move($0); return $0 }) { monitors.append(m) }
        if let m = EventMonitor.local(matching: .leftMouseDown, handler: { click($0); return $0 }) { monitors.append(m) }
    }
}
