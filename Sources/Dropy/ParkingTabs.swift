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
    private var tabs: [UInt32: (identity: WindowIdentity, panels: [NSPanel])] = [:]

    /// Shows tabs over every visible piece of the parked window and returns the
    /// covered rectangles in global top-left coordinates.
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
            panel.orderFrontRegardless()
            return panel
        }
        tabs[entry.identity.windowID] = (entry.identity, panels)
        return parts
    }

    func remove(_ identity: WindowIdentity) {
        tabs.removeValue(forKey: identity.windowID)?.panels.forEach { $0.orderOut(nil) }
    }

    func removeAll() {
        tabs.values.forEach { $0.panels.forEach { $0.orderOut(nil) } }
        tabs = [:]
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
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
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
