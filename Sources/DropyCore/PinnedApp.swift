import Foundation

/// What opening the overlay does for the pinned app, step by step. The app delegate
/// supplies what it sees; this decides, so the order can be tested without launching
/// anything.
///
/// A running app with a window is shown at once. An app that is not running is
/// launched; one that is running without a window is asked to open one (the same
/// request as clicking its Dock icon). Either way Dropy then waits for a window, and
/// gives up with a reason rather than leaving the preview empty with no word.
public enum PinnedAppStep: Equatable, Sendable {
    /// A window is available: select it.
    case select
    /// Launch the app, or ask the running app for a window, then wait.
    case open
    /// Already asked; check again shortly.
    case wait
    /// No window came in time.
    case giveUp(PinnedAppProblem)
}

public enum PinnedAppProblem: Equatable, Sendable {
    /// The app is not installed (anymore).
    case notInstalled
    /// Launched or asked, but no capturable window appeared.
    case noWindow

    public func message(appName: String) -> String {
        switch self {
        case .notInstalled: "\(appName) is not installed. Choose another app in Settings."
        case .noWindow: "\(appName) has no window to show. Open one in \(appName), then Refresh."
        }
    }
}

public enum PinnedAppPlan {
    /// How long a launch may take before Dropy stops waiting for a window.
    public static let windowTimeout: TimeInterval = 12
    /// How often the window list is checked while waiting.
    public static let pollInterval: TimeInterval = 0.4

    public static func next(installed: Bool, hasWindow: Bool, asked: Bool, waited: TimeInterval) -> PinnedAppStep {
        if hasWindow { return .select }
        guard installed else { return .giveUp(.notInstalled) }
        guard asked else { return .open }
        return waited < windowTimeout ? .wait : .giveUp(.noWindow)
    }
}
