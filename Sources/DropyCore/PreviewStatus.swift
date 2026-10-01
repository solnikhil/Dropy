import Foundation

/// The line under the preview: what the capture is doing, and the one thing about a
/// hidden source that the picture cannot show by itself.
public enum PreviewStatus {
    /// Kept here so the picker's wording and the note it may be replaced by stay together.
    public static let choose = "Choose a window · live preview only"
    public static let noWindows = "No capturable windows. Open an app and refresh."

    /// - Parameters:
    ///   - hasWindows: the picker found at least one capturable window.
    ///   - hiddenSource: what the changed-frame rate says about the source Dropy hid.
    public static func line(phase: CapturePhase, hasWindows: Bool,
                            hiddenSource: HiddenSourceRateMonitor.Assessment) -> String {
        switch phase {
        // A closed overlay has no status field to read this; it keeps a line from the
        // last session from reappearing for an instant when the panel is rebuilt.
        case .closed: return ""
        case .selecting: return hasWindows ? choose : noWindows
        case .starting, .paused, .failed:
            // A rate measured while frames were flowing says nothing once they stop or
            // the capture fails, so those phases never carry the note.
            return phase.message ?? ""
        case .viewing:
            // The note replaces the generic live-preview wording rather than extending
            // it: that the preview is live is visible in the picture, the source's
            // frame rate is not, and the status field truncates.
            return HiddenSourceRateMonitor.label(hiddenSource) ?? phase.message ?? ""
        }
    }
}
