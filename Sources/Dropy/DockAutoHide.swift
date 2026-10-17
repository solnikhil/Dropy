import AppKit
import DropyCore

/// Hides the Dock while the overlay is open on the Dock's edge, if the person asked
/// for it: the Dock slides away as the overlay grows and comes back once it has
/// closed. macOS lets only the frontmost app hide the Dock for itself, and Dropy
/// never becomes frontmost, so this turns on the system's own "Automatically hide and
/// show the Dock" through System Events (an Automation permission) and turns it off
/// again after each closing, and when Dropy quits.
///
/// Dropy only ever undoes its own change: a marker in its defaults records that it
/// turned auto-hide on. A Dock the person already hides is left alone, and a marker
/// left by a crash is undone on the next launch.
@MainActor
final class DockAutoHide {
    private static let markerKey = "DropyTurnedOnDockAutoHide"
    /// After a closing, the Dock comes back once the outline has gone, not under it.
    static let returnDelay: TimeInterval = 0.35
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "org.dropy.dock-autohide")
    /// Called with a message when the setting cannot be changed, or nil once it works.
    var onProblem: ((String?) -> Void)?
    private var wanted = false
    /// A change on its way to System Events, so another is not queued behind it.
    private var pending: Bool?
    private var pendingReturn: DispatchWorkItem?

    private var turnedOn: Bool {
        get { defaults.bool(forKey: Self.markerKey) }
        set { defaults.set(newValue, forKey: Self.markerKey) }
    }

    /// The Dock's edge, from its own settings.
    static var side: DockSide {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        return DockSide(orientation: CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String)
    }

    private static var systemAutoHide: Bool {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        return CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool ?? false
    }

    /// The Dock an opening with `preferences` hides, if any.
    static func sideToHide(for preferences: DropyPreferences) -> DockSide? {
        let side = side
        return preferences.position.hidesDock(preference: preferences.hidesDock, dock: side) ? side : nil
    }

    /// The overlay opened or a preference changed while it is open: hide the Dock now
    /// if this opening sits on its edge.
    func overlayOpened(_ preferences: DropyPreferences) {
        pendingReturn?.cancel()
        pendingReturn = nil
        apply(Self.sideToHide(for: preferences) != nil)
    }

    /// The overlay closed: the Dock comes back after the closing motion.
    func overlayClosed(after delay: TimeInterval) {
        pendingReturn?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply(false) }
        pendingReturn = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + Self.returnDelay, execute: work)
    }

    /// At launch: undo a change a crash left behind.
    func settle() { apply(false) }

    /// Puts the person's setting back before Dropy quits.
    func restoreNow() {
        pendingReturn?.cancel()
        guard turnedOn else { return }
        if Self.run(false) == nil { turnedOn = false }
    }

    private func apply(_ hidden: Bool) {
        wanted = hidden
        guard pending == nil else { return }
        if hidden, !turnedOn {
            // The person hides the Dock already: nothing to change or to undo.
            guard !Self.systemAutoHide else { onProblem?(nil); return }
            set(true)
        } else if !hidden, turnedOn {
            set(false)
        }
    }

    private func set(_ hidden: Bool) {
        pending = hidden
        queue.async {
            let problem = Self.run(hidden)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = nil
                if problem == nil { self.turnedOn = hidden }
                NSLog("Dropy dock: auto-hide %@ %@", hidden ? "on" : "off", problem ?? "done")
                self.onProblem?(problem)
                // The overlay may have opened or closed while this ran.
                if problem == nil, self.wanted != hidden { self.apply(self.wanted) }
            }
        }
    }

    /// Sets the system's auto-hide; returns why it failed, or nil.
    nonisolated private static func run(_ hidden: Bool) -> String? {
        let source = "tell application \"System Events\" to set autohide of dock preferences to \(hidden)"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        let number = error[NSAppleScript.errorNumber] as? Int
        if number == -1743 {
            return "Allow Dropy to control System Events in System Settings › Privacy & Security › Automation."
        }
        return "Dropy could not change the Dock (\(error[NSAppleScript.errorMessage] as? String ?? "error \(number ?? 0)"))."
    }
}
