import AppKit

// Regression checks for two dismissal bugs found by Scripts/dismissal-checks.sh:
// the panel hid itself when Dropy deactivated, and the pointer-tracking callbacks were
// exported under a selector AppKit never calls.
@main
struct OverlayPanelChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let panel = OverlayPanel.make(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200))
        precondition(!panel.hidesOnDeactivate, "the overlay must not vanish when another app is clicked")
        precondition(panel.canBecomeKey && panel.level == .statusBar)
        precondition(panel.collectionBehavior.contains(.canJoinAllSpaces))

        let topFrame = CGRect(x: 100, y: 900, width: 600, height: 212)
        precondition(panel.constrainFrameRect(topFrame, to: NSScreen.main) == topFrame,
                     "the menu-bar overlay must retain its top alignment")
        let root = PointerTrackingView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        var entered = 0, exited = 0
        root.onEntered = { entered += 1 }
        root.onExited = { exited += 1 }
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        // AppKit delivers tracking events as -mouseEntered:/-mouseExited: to the owner.
        root.perform(#selector(NSResponder.mouseEntered(with:)), with: event)
        root.perform(#selector(NSResponder.mouseExited(with:)), with: event)
        precondition(entered == 1 && exited == 1, "tracking callbacks must reach the overlay")
        print("Overlay panel checks passed")
    }
}
