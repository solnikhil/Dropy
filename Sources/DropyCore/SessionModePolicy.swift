import Foundation

/// How one opening of the overlay shows the chosen window.
public enum SessionMode: String, Equatable, Sendable {
    /// The real window moves into the overlay and its app comes to the front.
    case native
    /// The window stays on Dropy's Stage display and is streamed into the overlay,
    /// with the pointer handed over (planned: docs/design/2026-10-07-interaction-engine-plan.md).
    case live
    /// A view-only stream of the window.
    case preview
}

/// What decides the mode for a session.
public struct SessionConditions: Equatable, Sendable {
    public var isPinned: Bool
    public var interaction: InteractionMode
    /// Accessibility is granted, so Dropy may move windows and bring apps forward.
    public var accessibilityTrusted: Bool
    /// The notch display's current desktop is another app's full-screen space, which
    /// an ordinary window cannot join.
    public var fullScreenInFront: Bool
    /// Dropy's Stage display exists and works.
    public var stageAvailable: Bool

    public init(interaction: InteractionMode, accessibilityTrusted: Bool, fullScreenInFront: Bool = false,
                stageAvailable: Bool = false, isPinned: Bool = false) {
        self.isPinned = isPinned
        self.interaction = interaction
        self.accessibilityTrusted = accessibilityTrusted
        self.fullScreenInFront = fullScreenInFront
        self.stageAvailable = stageAvailable
    }
}

public enum SessionModePolicy {
    public static func mode(for conditions: SessionConditions) -> SessionMode {
        guard !conditions.isPinned else { return .preview }
        guard conditions.interaction == .fullApp, conditions.accessibilityTrusted else { return .preview }
        if conditions.fullScreenInFront { return conditions.stageAvailable ? .live : .preview }
        return .native
    }

    /// Why a session that the person wanted to use is only a preview, shown over it;
    /// nil when the person chose Preview or nothing needs explaining.
    public static func previewNote(for conditions: SessionConditions) -> String? {
        if conditions.isPinned { return "Pinned · View only" }
        guard conditions.interaction == .fullApp, mode(for: conditions) == .preview else { return nil }
        if !conditions.accessibilityTrusted {
            return "View only · Allow Accessibility for Dropy in Settings to use apps here"
        }
        return "View only · An app can't be brought over a full-screen app yet"
    }
}
