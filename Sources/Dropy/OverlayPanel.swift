import AppKit

/// The overlay's root view: reports the pointer entering and leaving the panel.
final class PointerTrackingView: NSView {
    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?
    override func mouseEntered(with event: NSEvent) { onEntered?() }
    override func mouseExited(with event: NSEvent) { onExited?() }
}

final class OverlayPanel: NSPanel {
    /// The overlay panel as Dropy shows it.
    static func make(contentRect: CGRect) -> OverlayPanel {
        // Non-activating: clicking the overlay's controls while a docked app is in front
        // leaves that app in front, so its keyboard focus is not taken away.
        let panel = OverlayPanel(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Clear: the overlay's outline (MorphBackdropView) draws the shape, with
        // rounded corners and the curves where it joins the top edge.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // An active window's shadow was re-rendered on every composite while content
        // behind it changed, adding about 25 points of GPU utilization with nothing
        // captured. A hairline border separates the panel instead.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        // NSPanel hides itself when its app deactivates. Clicking another app then made
        // the overlay vanish while Dropy still considered it open ("manual" and
        // "pointer leaves" modes), so the notch could not reopen it. Closing is decided
        // by the dismiss preference alone.
        panel.hidesOnDeactivate = false
        // No system "window appears" zoom: it scaled the panel in from slightly smaller,
        // so for the first frames of every opening its top edge sat below the screen's
        // (up to 6 points on the first opening) and the menu bar showed above the outline.
        // The outline's own morph is the opening animation.
        panel.animationBehavior = .none
        return panel
    }

    /// This borderless surface intentionally covers the menu-bar band. AppKit
    /// must not move it down to the display’s visibleFrame during a resize.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    var onEscape: (() -> Void)?
    /// Window-list keys; returns true when it consumed the key.
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
    /// Command-W from the menu bar closes the overlay like Esc (a borderless panel
    /// would only beep).
    override func performClose(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

