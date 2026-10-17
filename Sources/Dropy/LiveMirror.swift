import AppKit
import DropyCore

/// Live mode's picture: a click-through panel over the overlay's display showing the
/// Stage one to one. The docked app's window lands exactly in the overlay's cut-out,
/// as a docked window does, and its menus, popovers and sheets show wherever they open,
/// inside the overlay or not. Nothing is scaled, so the pointer hand-off is a plain
/// offset and the app is as sharp as on the Stage.
@MainActor
final class LiveMirror {
    private let panel: NSPanel
    let renderer: MetalFrameView

    /// `frame` is where the Stage shows, in AppKit screen coordinates.
    init?(frame: CGRect) {
        guard let renderer = try? MetalFrameView.make(frame: CGRect(origin: .zero, size: frame.size), transparent: true)
        else { return nil }
        self.renderer = renderer
        // The stream is the Stage at this size, so fitting it is one to one.
        renderer.contentMode = .fit
        renderer.autoresizingMask = [.width, .height]
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        // Above the overlay (status-bar level) like the app's menus, below Dropy's cursor.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = renderer
    }

    /// Ordered in before the stream starts: the stream's pixel size comes from this
    /// window's backing scale, and nothing shows until the first frame.
    func show() { panel.orderFrontRegardless() }

    func move(to frame: CGRect) {
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: false)
    }

    func close() {
        panel.orderOut(nil)
        renderer.clear()
    }
}
