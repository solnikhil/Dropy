import AppKit
import DropyCore

/// Covers the strip of a parked window that AppKit keeps on screen with a small
/// Dropy tab, so the source is out of sight while it keeps rendering (covered
/// windows keep capturing). Clicking a tab asks for the window back.
///
/// Tabs live only in this process: if Dropy crashes they vanish with it and the
/// placement journal restores the window at the next launch.
@MainActor
final class ParkingTabs {
    /// Called when a tab is clicked, with the parked window's identity.
    var onRestoreRequest: ((WindowIdentity) -> Void)?
    private var tabs: [UInt32: (identity: WindowIdentity, panels: [NSPanel], covered: [CGRect])] = [:]

    /// Shows tabs over every visible piece of the parked window and returns what they
    /// cover in global top-left coordinates.
    @discardableResult
    func show(for entry: PlacementEntry) -> [CGRect] {
        remove(entry.identity)
        let displays = WindowPlacer.displayBounds()
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let parts = PlacementGeometry.visibleParts(of: entry.applied.frame, on: displays)
        let icon = NSRunningApplication(processIdentifier: entry.identity.processID)?.icon
        let panels = parts.map { part -> NSPanel in
            let frame = PlacementGeometry.appKitRect(fromGlobal: part, mainDisplayHeight: mainHeight)
            let panel = TabPanel(frame: frame, icon: icon) { [weak self] in
                self?.onRestoreRequest?(entry.identity)
            }
            panel.title = "Dropy parking:\(entry.identity.windowID)"
            panel.orderFrontRegardless()
            return panel
        }
        // What AppKit realized, read back after ordering front, not what Dropy asked
        // for: a panel frame can be rounded to the backing grid or constrained, and a
        // fraction of a point short is the case `concealmentTolerance` exists for.
        // Claiming the requested rect instead would overstate the coverage.
        let covered = panels.map {
            PlacementGeometry.globalRect(fromAppKit: $0.frame, mainDisplayHeight: mainHeight)
        }
        tabs[entry.identity.windowID] = (entry.identity, panels, covered)
        return covered
    }

    /// What this process currently covers of the parked window, in global top-left
    /// coordinates; empty when Dropy shows no tab for that exact window.
    func covered(_ identity: WindowIdentity) -> [CGRect] {
        guard let tab = tabs[identity.windowID], tab.identity == identity else { return [] }
        return tab.covered
    }

    func remove(_ identity: WindowIdentity) {
        tabs.removeValue(forKey: identity.windowID)?.panels.forEach { $0.orderOut(nil) }
    }

    func removeAll() {
        tabs.values.forEach { $0.panels.forEach { $0.orderOut(nil) } }
        tabs = [:]
    }
}

/// Gathers what Dropy knows about its own containment of a source window: the journal
/// says what Dropy placed, the window server says where the window is now, and the
/// parking tabs say what Dropy covers.
///
/// Read on the main actor when a placement changes and about once a second while a
/// source is hidden, never per frame: the window-server query is the only cost, and a
/// window Dropy never placed costs nothing but a lookup in the journal it holds already.
@MainActor
struct SourceContainmentReader {
    let journal: PlacementJournal
    let tabs: ParkingTabs

    func containment(of identity: WindowIdentity) -> SourceContainment {
        guard let entry = journal.entries.first(where: { $0.identity == identity }) else {
            return SourceContainment()
        }
        let server = WindowPlacer.windowServerInfo(identity.windowID)
        return SourceContainment(mode: entry.mode, bounds: server?.bounds,
                                 isOnScreen: server?.onScreen ?? false,
                                 displays: WindowPlacer.displayBounds(),
                                 covered: tabs.covered(identity))
    }
}

/// A borderless, non-activating panel above normal windows that shows the parked
/// app's icon when it fits and reports clicks.
private final class TabPanel: NSPanel {
    private let onClick: () -> Void

    init(frame: CGRect, icon: NSImage?, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Above normal windows, so the parked source cannot rise over its tab.
        level = .floating
        backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = TabView(frame: CGRect(origin: .zero, size: frame.size), icon: icon)
        view.onClick = { [weak self] in self?.onClick() }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class TabView: NSView {
        var onClick: (() -> Void)?
        private let icon: NSImage?

        init(frame: CGRect, icon: NSImage?) {
            self.icon = icon
            super.init(frame: frame)
            toolTip = "Dropy parked this window. Click to bring it back."
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            let side = min(bounds.width, bounds.height) - 8
            guard let icon, side >= 16 else { return }
            icon.draw(in: CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                                 width: side, height: side))
        }

        override func mouseDown(with event: NSEvent) { onClick?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
