import AppKit
import ApplicationServices

/// Tells when Mission Control, App Exposé or Show Desktop begins. macOS posts no
/// public notification for them, but the Dock, which draws them, sends these
/// Accessibility notifications from its own application element (window managers
/// such as yabai rely on the same ones). Needs Accessibility; without it nothing is
/// reported and the overlay simply stays open, as before.
@MainActor
final class MissionControlWatcher {
    var onBegin: (() -> Void)?
    private var observer: AccessibilityObservation?
    private var dockPID: pid_t = 0

    private static let notifications = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop"]

    /// Starts watching, or restarts after the Dock relaunched. Cheap when already watching.
    func start() {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        guard observer == nil || dock.processIdentifier != dockPID else { return }
        stop()
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        observer = AccessibilityObservation(processID: dock.processIdentifier,
            notifications: Self.notifications.map { (element, $0) }) { [weak self] name in
                NSLog("Dropy dismiss: %@", name)
                self?.onBegin?()
            }
        guard observer != nil else { return }
        dockPID = dock.processIdentifier
    }

    func stop() {
        observer = nil
        dockPID = 0
    }
}
