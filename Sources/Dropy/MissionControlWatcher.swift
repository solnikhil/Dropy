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
    private var observer: AXObserver?
    private var dockPID: pid_t = 0

    private static let notifications = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop"]

    /// Starts watching, or restarts after the Dock relaunched. Cheap when already watching.
    func start() {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        guard observer == nil || dock.processIdentifier != dockPID else { return }
        stop()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<MissionControlWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated {
                NSLog("Dropy dismiss: %@", name)
                watcher.onBegin?()
            }
        }
        guard AXObserverCreate(dock.processIdentifier, callback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var added = 0
        for name in Self.notifications where AXObserverAddNotification(created, element, name as CFString, refcon) == .success {
            added += 1
        }
        guard added > 0 else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        dockPID = dock.processIdentifier
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        dockPID = 0
    }
}
