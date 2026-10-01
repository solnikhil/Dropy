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
        /// Everything a hand-off does to the window needs Accessibility: putting it back,
        /// raising it, and reading whether it is minimized at all.
        case accessibilityNotTrusted
        /// The window is there but its condition cannot be told: it is on another Space,
        /// its app did not answer, or an Accessibility read failed. Its minimized state is
        /// unknown in particular, and handing over a window that stays in the Dock would
        /// leave the person typing into nothing while Dropy said the window was theirs.
        case sourceUnreadable
    }

    // MARK: What the person sees

    /// Shown for as long as a hand-off lasts.
    public static let label = "Typing in real window"
    /// The button that starts one.
    public static let startTitle = "Type in the real window"
    /// The same button while one is running.
    public static let endTitle = "Back to the preview"
    /// Shown when anything is aimed at the preview while the real window has the typing.
    public static let inputRefusedLabel = "Preview input is off"
    /// Shown when the window could not be put back or reached, so nothing was handed over.
    public static let failedLabel = "Could not hand the real window over"

    /// The hand-off text the overlay keeps on screen rather than flashing: the state
    /// itself, and the refusal shown whenever input is aimed at the paused preview.
    /// Truncated, either one stops telling the person where their keyboard goes, so both
    /// must fit the status field at every size preset. `Tests/LocalOverlayPanelCheck.swift`
    /// measures them against `OverlayStatusLayout.interactionWidth(overlayWidth:)` with the
    /// font AppKit draws them in; transient messages share that field's ordinary
    /// truncation.
    public static let persistentStatusText = [label, inputRefusedLabel]

    public static func message(for refusal: Refusal) -> String {
        switch refusal {
        case .notRequestedByPerson: "Hand-off starts only when you ask for it"
        case .sourceGone: "The source window is gone"
        case .placementUnresolved: "Recover the pending window move first"
        case .accessibilityNotTrusted: "Allow Accessibility first"
        case .sourceUnreadable: "The window cannot be read"
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
    /// A running hand-off always offers its end, whatever the preferences or the
    /// permissions say now: the person must never be left with a handed-over window and
    /// no way back, not even if Accessibility is switched off while they type.
    /// - Parameters:
    ///   - interactivePreview: the person switched interactive preview on.
    ///   - trusted: Dropy has Accessibility permission. Without it the window cannot be
    ///     put back, raised or even read, so the button would promise what it cannot do.
    ///   - capturing: a source window is selected and being shown.
    ///   - typingVerified: in-preview typing is verified for this exact source, so the
    ///     hand-off would give up containment for nothing.
    ///   - active: a hand-off is running.
    public static func offer(interactivePreview: Bool, trusted: Bool, capturing: Bool,
                             typingVerified: Bool, active: Bool) -> Offer {
        if active { return .end(title: endTitle, label: label) }
        guard interactivePreview, trusted, capturing, !typingVerified else { return .hidden }
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
    ///   - trusted: Dropy has Accessibility permission.
    ///   - entry: the journal's placement of this window, if Dropy has placed it.
    ///   - read: what the source window is now; every case but `.state` means Dropy
    ///     cannot tell, and a hand-off is never started on a guess.
    ///   - frontmost: the frontmost app's process ID before the hand-off.
    ///   - source: the source window's process ID.
    public static func start(trigger: Trigger, trusted: Bool, entry: PlacementEntry?, read: SourceWindowRead,
                             displays: [CGRect], frontmost: Int32?, source: Int32) -> Result<Start, Refusal> {
        guard trigger == .personRequest else { return .failure(.notRequestedByPerson) }
        // Without Accessibility the window cannot be put back, cannot be raised, and its
        // minimized state cannot even be read; the only possible outcome is a hand-off
        // Dropy claims to have made and has not.
        guard trusted else { return .failure(.accessibilityNotTrusted) }
        let current: WindowPlacementState
        switch read {
        case .state(let state): current = state
        case .unreachable(let diagnosis):
            // A window that may come back is not a window that is gone, and it is not a
            // window Dropy knows anything about either.
            return .failure(diagnosis.mayBecomeReachable ? .sourceUnreadable : .sourceGone)
        case .failed: return .failure(.sourceUnreadable)
        }
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
    ///   - read: what the source window is now. Anything but `.state` means Dropy cannot
    ///     see where the window is, and nothing is re-parked on a state it cannot see.
    ///   - frontmost: the frontmost app now.
    ///   - source: the source window's process ID.
    ///   - returnAppRunning: whether the app to return focus to still runs.
    public static func end(_ start: Start, read: SourceWindowRead, frontmost: Int32?, source: Int32,
                           returnAppRunning: Bool) -> End {
        // Focus goes back only if the person is still in the source app; if they
        // switched elsewhere, that choice wins too. It does not depend on reading the
        // window: a window on another Space is still the window they were typing in.
        let focus = frontmost == source && returnAppRunning ? start.returnFocusTo : nil
        // A window Dropy cannot read may be one the person is using; it is left alone.
        guard case .state(let current) = read else { return End(repark: nil, activate: focus) }
        // Any move, resize, minimize or hide during the hand-off is the person's; it wins.
        let untouched = current.approximatelyEquals(start.expected)
        return End(repark: untouched ? start.reparkMode : nil, activate: focus)
    }

    // MARK: Settling the write-ahead record

    /// What to do with the placement entry that carried the hand-off record, once the
    /// hand-off is over: it ended, it never started, or its window is gone.
    public enum Settlement: Equatable, Sendable {
        /// Dropy had placed nothing, so there is no entry and nothing to settle.
        case nothingJournaled
        /// The window is no longer where Dropy put it, so that placement is finished:
        /// drop the whole entry. A re-park, being a new placement, needs this.
        case dropEntry
        /// The window may still be where Dropy put it, or could not be read at all: the
        /// placement is still in force. Keep the entry, clear only the hand-off record,
        /// and leave the placement to the ordinary recovery.
        case keepPlacementAndRecover
    }

    /// Settles the write-ahead record from what the window is observed to be, never from
    /// what Dropy asked for.
    ///
    /// Starting a hand-off can fail at every step, and each failure leaves the window
    /// where Dropy parked it: Accessibility can be off or revoked mid-way, the window can
    /// drop out of the Accessibility tree, and a position write can be refused or
    /// silently ignored. The entry is the only record of where such a window belongs, so
    /// it is dropped only once the window has been read somewhere else; anything else
    /// keeps the placement and asks recovery to finish it.
    public static func settle(_ entry: PlacementEntry?, read: SourceWindowRead) -> Settlement {
        guard let entry else { return .nothingJournaled }
        guard case .state(let current) = read else { return .keepPlacementAndRecover }
        return current.approximatelyEquals(entry.applied) ? .keepPlacementAndRecover : .dropEntry
    }

    // MARK: Who may touch the hand-off

    /// Serializes starting and ending, so the two can never both change the record, the
    /// input refusal, or the window.
    ///
    /// A start suspends while the window is put back, which takes as long as another app
    /// needs to answer Accessibility. An end asked for in that gap — a second click on
    /// the button, the overlay reopening, another window chosen, the source app quitting —
    /// must not clear the hand-off under the running start: the real window would end up
    /// with the person's keyboard while the preview no longer refused input, and the
    /// record the start is still writing would be settled behind it. Such an end waits
    /// and runs the moment the start finishes.
    ///
    /// Every start and every end also bumps `generation`, so work that suspends can tell
    /// its own hand-off is over: the re-park an ended hand-off planned must never move a
    /// window a newer hand-off has just given back to the person.
    public struct Lifecycle: Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            case idle
            /// A start is running: the record may already exist and input is already
            /// refused, but the window is not yet in the person's hands.
            case starting
            case active
        }

        public private(set) var phase: Phase
        public private(set) var generation: Int
        /// The reason an end was asked for while a start was running, if any.
        public private(set) var deferredEnd: String?

        public init() {
            phase = .idle
            generation = 0
            deferredEnd = nil
        }

        public enum StartRequest: Equatable, Sendable {
            case begin(generation: Int)
            /// One is already running or starting; a second may not touch anything.
            case ignore
        }

        public mutating func requestStart() -> StartRequest {
            guard phase == .idle else { return .ignore }
            phase = .starting
            generation += 1
            return .begin(generation: generation)
        }

        public enum EndRequest: Equatable, Sendable {
            case end(generation: Int)
            /// A start is running; it carries this end out when it finishes.
            case deferred
            /// Nothing is running, so there is nothing to end.
            case ignore
        }

        public mutating func requestEnd(reason: String) -> EndRequest {
            switch phase {
            case .idle: return .ignore
            case .starting:
                // The first reason to ask is kept: the outcome is the same either way,
                // and it is the one that asked for the hand-off to stop.
                if deferredEnd == nil { deferredEnd = reason }
                return .deferred
            case .active:
                phase = .idle
                generation += 1
                return .end(generation: generation)
            }
        }

        /// The window is the person's: the hand-off is running. Returns the reason to end
        /// it at once when an end was asked for while the start ran, and nil otherwise.
        public mutating func started() -> String? {
            guard phase == .starting else { return nil }
            phase = .active
            defer { deferredEnd = nil }
            return deferredEnd
        }

        /// The start never handed the window over, so an end asked for meanwhile has
        /// nothing to end, and anything still in flight from this start is stale.
        public mutating func startFailed() {
            guard phase == .starting else { return }
            phase = .idle
            deferredEnd = nil
            generation += 1
        }

        /// Whether work that suspended still belongs to the current hand-off.
        public func isCurrent(_ generation: Int) -> Bool { self.generation == generation }
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
