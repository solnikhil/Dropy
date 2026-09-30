import CoreGraphics
import Foundation

/// A write-ahead record of a hand-off, kept on the placement entry of the window being
/// handed over. It is written before the window is touched and removed when the hand-off
/// ends, so an interrupted one is recognizable at the next launch.
///
/// It deliberately carries no placement to re-apply: re-parking happens only through
/// `HandOff.end`, from the plan held in memory, so no crash can re-park a window the
/// person was typing in.
public struct HandOffRecord: Codable, Equatable, Sendable {
    /// Where the window belongs while the hand-off lasts: on screen, not minimized and
    /// not hidden. A crash leaves the window here, or an interrupted move is completed
    /// to here at the next launch.
    public var restoredTo: WindowPlacementState
    public var startedAt: Date

    public init(restoredTo: WindowPlacementState, startedAt: Date) {
        self.restoredTo = restoredTo
        self.startedAt = startedAt
    }
}

/// Hand-off typing (ARCHITECTURE, typing design, mode 2): the decisions only, with no
/// AppKit or Accessibility calls, so every gate is testable.
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

    // MARK: What the person sees

    /// Shown while a hand-off lasts.
    public static let label = "Typing in the real window · the preview is paused"
    /// The button that starts one.
    public static let startTitle = "Type in the real window"
    /// The same button while one is running.
    public static let endTitle = "Back to the preview"
    /// Shown when anything is aimed at the preview while the real window has the typing.
    public static let inputRefusedLabel = "Preview input is off during hand-off"
    /// Shown when the window could not be put back or reached, so nothing was handed over.
    public static let failedLabel = "Could not hand the real window over"

    public static func message(for refusal: Refusal) -> String {
        switch refusal {
        case .notRequestedByPerson: "Hand-off starts only when you ask for it"
        case .sourceGone: "The source window is gone"
        case .placementUnresolved: "Recover the pending window move first"
        }
    }

    /// What the overlay offers for the hand-off.
    public enum Offer: Equatable, Sendable {
        /// No button: there is no source to hand over, interactive preview is off, or
        /// in-preview typing is already verified for this source, so nothing is given up.
        case hidden
        case start(title: String)
        /// A hand-off is running: offer to take the typing back, and say so.
        case end(title: String, label: String)
    }

    /// Whether the overlay shows the hand-off button, and what it says.
    ///
    /// A running hand-off always offers its end, whatever the preferences say now: the
    /// person must never be left with a handed-over window and no way back.
    /// - Parameters:
    ///   - interactivePreview: the person switched interactive preview on.
    ///   - capturing: a source window is selected and being shown.
    ///   - typingVerified: in-preview typing is verified for this exact source, so the
    ///     hand-off would give up containment for nothing.
    ///   - active: a hand-off is running.
    public static func offer(interactivePreview: Bool, capturing: Bool, typingVerified: Bool,
                             active: Bool) -> Offer {
        if active { return .end(title: endTitle, label: label) }
        guard interactivePreview, capturing, !typingVerified else { return .hidden }
        return .start(title: startTitle)
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
        // A record left by an interrupted hand-off says the window's position is not yet
        // settled. Recovery must finish it before Dropy moves the window again.
        guard entry?.handOff == nil else { return .failure(.placementUnresolved) }
        let focus = frontmost == source ? nil : frontmost
        let label = Self.label
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

    // MARK: Surviving a crash

    /// The journal record to write before the source window is touched, so a crash during
    /// the hand-off puts the window back and re-parks nothing.
    ///
    /// Nil when Dropy has placed nothing. The placement journal records Dropy's own
    /// placements; inventing one for a window the person minimized, hid or moved
    /// themselves would authorize a later restore to undo their own choice. With no
    /// placement there is also nothing a crash could leave out of reach.
    public static func record(_ plan: Start, on entry: PlacementEntry?, at time: Date) -> PlacementEntry? {
        guard var entry else { return nil }
        entry.handOff = HandOffRecord(restoredTo: plan.expected, startedAt: time)
        return entry
    }

    /// Least of a window that must lie on a display for the person to reach it with
    /// ordinary controls. A parked window keeps only the strip AppKit refuses to hide.
    public static let reachableFraction = 0.5

    /// A window an interrupted hand-off must put back because the person cannot get to it:
    /// mostly beyond every display. Minimized and hidden are not included; the Dock and
    /// ⌘Tab still reach those, and the person may have minimized it themselves.
    public static func isOutOfReach(_ state: WindowPlacementState, on displays: [CGRect]) -> Bool {
        !displays.isEmpty && PlacementGeometry.visibleFraction(of: state.frame, on: displays) < reachableFraction
    }

    /// What to do with a journal entry whose hand-off was interrupted by a crash or a
    /// forced quit. It never re-parks: the placement to re-apply lives only in `End`, in
    /// memory, and dies with the process.
    ///
    /// The window is put where the hand-off wanted it when Dropy's placement is still in
    /// force (the restore never took effect) or when an interrupted move left it out of
    /// reach. A window the person can see and reach is left alone: a move made during a
    /// hand-off wins, exactly as it does when one ends normally. A window that is still
    /// minimized or hidden exactly as Dropy placed it is shown again, because Dropy's own
    /// placement cannot be told from the person repeating it.
    public static func recovery(_ entry: PlacementEntry, handOff: HandOffRecord,
                                current: WindowPlacementState, displays: [CGRect]) -> RestoreDecision {
        let target = handOff.restoredTo
        // Already where the hand-off put it: nothing to change, and the record goes.
        if current.approximatelyEquals(target) { return .keepUserChange }
        guard current.approximatelyEquals(entry.applied) || isOutOfReach(current, on: displays) else {
            return .keepUserChange
        }
        guard !displays.isEmpty,
              PlacementGeometry.visibleFraction(of: target.frame, on: displays) == 0 else {
            return .restore(target)
        }
        var moved = target
        moved.frame = PlacementGeometry.clamp(target.frame, into: displays[0])
        return .restoreOnFallbackDisplay(moved)
    }
}
