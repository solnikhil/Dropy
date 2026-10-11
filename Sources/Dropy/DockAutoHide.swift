import AppKit
import DropyCore

/// Keeps the Dock hidden while the overlay opens on the Dock's edge, if the person
/// asked for it. macOS lets only the frontmost app hide the Dock for itself, and
/// Dropy never becomes frontmost, so this turns on the system's own "Automatically
/// hide and show the Dock" through System Events (an Automation permission) and puts
/// the person's setting back when it is no longer needed and when Dropy quits.
///
/// Dropy only ever undoes its own change: a marker in its defaults records that it
/// turned auto-hide on. A Dock the person already hides is left alone, and a marker
/// left by a crash is honored on the next launch.
@MainActor
final class DockAutoHide {
    private static let markerKey = "DropyTurnedOnDockAutoHide"
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "org.dropy.dock-autohide")
    /// Called with a message when the setting cannot be changed, or nil once it works.
    var onProblem: ((String?) -> Void)?
    private var wanted = false

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

    /// Brings the Dock in line with the preferences.
    func update(_ preferences: DropyPreferences) {
        let wanted = preferences.position.hidesDock(preference: preferences.hidesDock, dock: Self.side)
        self.wanted = wanted
        if wanted, !turnedOn {
            guard !Self.systemAutoHide else { onProblem?(nil); return }
            set(true)
        } else if !wanted, turnedOn {
            set(false)
        } else {
            onProblem?(nil)
        }
    }

    /// Puts the person's setting back before Dropy quits.
    func restoreNow() {
        guard turnedOn else { return }
        if Self.run(false) == nil { turnedOn = false }
    }

    private func set(_ hidden: Bool) {
        queue.async {
            let problem = Self.run(hidden)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if problem == nil { self.turnedOn = hidden }
                NSLog("Dropy dock: auto-hide %@ %@", hidden ? "on" : "off", problem ?? "done")
                self.onProblem?(problem)
                // The preference may have changed while this ran.
                if problem == nil, self.wanted != hidden, self.turnedOn == hidden { self.set(self.wanted) }
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
