import CoreGraphics
import Foundation

/// Hand-off typing (ARCHITECTURE, typing design, mode 2): the decisions only, with no
/// AppKit or Accessibility calls, so every gate is testable. Not wired into the app.
///
/// On an explicit request from the person, Dropy undoes its placement of the source
/// window, raises it and makes its app frontmost, and says so; the person then types
/// into the real window with every key, input method and shortcut working natively.
/// This gives up containment while typing, by design. Ending the hand-off re-parks the
/// window only if the person left it where Dropy put it back, and returns focus only
/// if the person is still in the source app.
public enum HandOff {
    /// What asked for the hand-off. Only a person's action may start one.
    public enum Trigger: Equatable, Sendable {
        case personRequest
        /// Anything automatic (a timer, a key routed from the preview, a restore).
        case automatic
    }

    public enum Refusal: Error, Equatable, Sendable {
        case notRequestedByPerson
        /// The exact window is gone.
        case sourceGone
        /// A crash-interrupted placement cannot be told from a person's move; the
        /// journal must be resolved by the existing recovery before anything else moves.
        case placementUnresolved
    }

    /// What starting the hand-off does, in order.
    public struct Start: Equatable, Sendable {
        /// Where to put the window back first; nil when it is not placed or the person
        /// already moved it (their move wins).
        public var restoreTo: WindowPlacementState?
        /// The placement to re-apply when the hand-off ends; nil if none should be.
        public var reparkMode: PlacementMode?
        /// The state Dropy expects after starting; a different state at the end means
        /// the person moved the window during the hand-off.
        public var expected: WindowPlacementState
        /// The app to give focus back to at the end (the frontmost one before), if any.
        public var returnFocusTo: Int32?
        /// Shown to the person while the hand-off lasts.
        public var label: String
    }

    /// - Parameters:
    ///   - entry: the journal's placement of this window, if Dropy has placed it.
    ///   - current: the window's state now; nil when the exact window is gone.
    ///   - frontmost: the frontmost app's process ID before the hand-off.
    ///   - source: the source window's process ID.
    public static func start(trigger: Trigger, entry: PlacementEntry?, current: WindowPlacementState?,
                             displays: [CGRect], frontmost: Int32?, source: Int32) -> Result<Start, Refusal> {
        guard trigger == .personRequest else { return .failure(.notRequestedByPerson) }
        guard let current else { return .failure(.sourceGone) }
        let focus = frontmost == source ? nil : frontmost
        let label = "Typing in the real window · the preview is paused"
        // Typing needs the window on screen: a minimized or hidden window is shown
        // where it is, never moved.
        func shownInPlace() -> Start {
            var shown = current
            shown.isMinimized = false
            shown.isAppHidden = false
            return Start(restoreTo: shown == current ? nil : shown, reparkMode: nil, expected: shown,
                         returnFocusTo: focus, label: label)
        }
        guard let entry else { return .success(shownInPlace()) }
        switch PlacementRestorer.decide(entry, current: current, displays: displays) {
        case .restore(let state), .restoreOnFallbackDisplay(let state):
            var shown = state
            // The person types into it, so it must not stay minimized or hidden.
            shown.isMinimized = false
            shown.isAppHidden = false
            return .success(Start(restoreTo: shown, reparkMode: entry.mode, expected: shown,
                                  returnFocusTo: focus, label: label))
        case .keepUserChange:
            // The person moved it since Dropy placed it: leave it, and do not re-park.
            return .success(shownInPlace())
        case .sourceGone: return .failure(.sourceGone)
        case .pending: return .failure(.placementUnresolved)
        }
    }

    /// What ending the hand-off does.
    public struct End: Equatable, Sendable {
        /// Re-apply this placement; nil to leave the window where it is.
        public var repark: PlacementMode?
        /// Activate this app; nil to leave focus alone.
        public var activate: Int32?

        public init(repark: PlacementMode?, activate: Int32?) {
            self.repark = repark
            self.activate = activate
        }
    }

    /// - Parameters:
    ///   - current: the window's state now; nil when it is gone.
    ///   - frontmost: the frontmost app now.
    ///   - source: the source window's process ID.
    ///   - returnAppRunning: whether the app to return focus to still runs.
    public static func end(_ start: Start, current: WindowPlacementState?, frontmost: Int32?, source: Int32,
                           returnAppRunning: Bool) -> End {
        guard let current else { return End(repark: nil, activate: nil) }
        // Any move, resize, minimize or hide during the hand-off is the person's; it wins.
        let untouched = current.approximatelyEquals(start.expected)
        // Focus goes back only if the person is still in the source app; if they
        // switched elsewhere, that choice wins too.
        let focus = frontmost == source && returnAppRunning ? start.returnFocusTo : nil
        return End(repark: untouched ? start.reparkMode : nil, activate: focus)
    }
}
