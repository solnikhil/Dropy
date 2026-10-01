import AppKit
import DropyCore

/// Runs hand-off typing (ARCHITECTURE, typing design, mode 2). On the person's explicit
/// request it undoes Dropy's placement of the source window, raises it, makes its app
/// frontmost and says so; the person then types in the real window with every key, input
/// method and shortcut working natively. Containment is given up while it lasts, by design.
///
/// Every decision belongs to `DropyCore/HandOff`; this type only carries them out with
/// AppKit and `WindowPlacer`. Two rules are structural here, not just checked:
/// - nothing may pass `.personRequest` except a control the person clicked, so no timer,
///   restore or key routed from the preview can start a hand-off;
/// - the placement to re-apply is held only in memory, so a crash can never re-park a
///   window the person was typing in. The journal's write-ahead record is written before
///   the window is touched and says only where the window belongs.
@MainActor
final class HandOffSession {
    struct Active {
        let identity: WindowIdentity
        let plan: HandOff.Start
    }

    enum StartResult: Equatable {
        case started
        /// A hand-off is already running or starting for this source.
        case ignored
        case refused(HandOff.Refusal)
        /// The window could not be put back or reached; nothing was handed over.
        case failed(String)
    }

    /// Called when the source is no longer parked, so its parking tab can go.
    var onRestored: ((WindowIdentity) -> Void)?
    /// Called after the end of a hand-off re-parked the window, so its tab can come back.
    var onReparked: ((PlacementEntry) -> Void)?
    /// Called whenever a hand-off starts or ends, so the overlay can relabel.
    var onChange: (() -> Void)?
    var onRecoveryRequired: ((WindowIdentity) -> Void)?

    private(set) var active: Active?
    private var lifecycle = HandOff.Lifecycle()
    private var ending = false
    private let journal: PlacementJournal

    init(journal: PlacementJournal) {
        self.journal = journal
    }

    func isActive(for identity: WindowIdentity?) -> Bool {
        guard let identity, let active else { return false }
        return active.identity == identity
    }

    /// Hands typing over to the exact window. `trigger` must come from a control the
    /// person clicked; `HandOff.start` refuses anything else.
    func start(_ identity: WindowIdentity, trigger: HandOff.Trigger) async -> StartResult {
        guard !ending, case .begin = lifecycle.requestStart() else { return .ignored }
        var completed = false
        defer { if !completed { lifecycle.startFailed() } }
        let entry = journal.entries.first { $0.identity == identity }
        let plan: HandOff.Start
        switch HandOff.start(trigger: trigger, trusted: WindowPlacer.isTrusted, entry: entry,
                             read: WindowPlacer.readForHandOff(identity),
                             displays: WindowPlacer.displayBounds(),
                             frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                             source: identity.processID) {
        case .success(let started): plan = started
        case .failure(let refusal):
            NSLog("Dropy hand-off refused: window=%u reason=%@", identity.windowID, String(describing: refusal))
            return .refused(refusal)
        }
        // Write-ahead: the record reaches the disk before the window is touched, so from
        // here on a crash puts the window back at the next launch and re-parks nothing.
        if let record = HandOff.record(plan, on: entry, at: Date()) {
            do { try journal.upsert(record) }
            catch {
                NSLog("Dropy hand-off journal write failed: %@", String(describing: error))
                return .failed("journalWriteFailed")
            }
        }
        active = Active(identity: identity, plan: plan)
        onChange?()
        if let restoreTo = plan.restoreTo {
            do { try await WindowPlacer.apply(restoreTo, to: identity) }
            catch {
                NSLog("Dropy hand-off restore failed: %@", String(describing: error))
                settle(identity)
                active = nil
                onChange?()
                return .failed(String(describing: error))
            }
        }
        guard case .state(let observed) = WindowPlacer.readForHandOff(identity),
              observed.approximatelyEquals(plan.expected), WindowPlacer.isTrusted else {
            settle(identity)
            active = nil
            onChange?()
            return .failed("restoreNotObserved")
        }
        // The window is the person's again: no tab may cover it, it comes to the front of
        // its own app, and that app comes to the front.
        onRestored?(identity)
        do { try WindowPlacer.raise(identity) }
        catch {
            settle(identity)
            active = nil
            onChange?()
            return .failed("raiseFailed")
        }
        if let reason = lifecycle.started() {
            completed = true
            end(reason: reason)
            return .ignored
        }
        completed = true
        NSRunningApplication(processIdentifier: identity.processID)?.activate()
        NSLog("Dropy hand-off started: window=%u restored=%@ repark=%@ returnFocus=%@",
              identity.windowID, plan.restoreTo == nil ? "no" : "yes",
              plan.reparkMode?.rawValue ?? "none", plan.returnFocusTo.map(String.init) ?? "none")
        return .started
    }

    /// Ends the hand-off from the state at this moment. `HandOff.end` alone decides whether
    /// the window is re-parked and where focus goes; nothing here may add to that.
    func end(reason: String) {
        guard !ending, case .end = lifecycle.requestEnd(reason: reason), let active else { return }
        ending = true
        let identity = active.identity
        let returnApp = active.plan.returnFocusTo.flatMap { NSRunningApplication(processIdentifier: $0) }
        let decision = HandOff.end(active.plan, read: WindowPlacer.readForHandOff(identity),
                                   frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                   source: identity.processID,
                                   returnAppRunning: returnApp?.isTerminated == false)
        let recordCleared = settle(identity)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.active = nil
                self.ending = false
                self.onChange?()
            }
            // Keep preview input refused and new starts blocked until the asynchronous
            // placement completes. There can be no newer hand-off moving the same source.
            if let mode = decision.repark, recordCleared,
               case .state(let observed) = WindowPlacer.readForHandOff(identity),
               observed.approximatelyEquals(active.plan.expected) {
                do { self.onReparked?(try await WindowPlacer.apply(mode, to: identity, journal: self.journal)) }
                catch {
                    NSLog("Dropy hand-off repark failed: %@", String(describing: error))
                    self.onRecoveryRequired?(identity)
                }
            }
            // Re-check focus after the awaited placement: a switch made while it ran wins.
            if let pid = decision.activate,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == identity.processID,
               NSRunningApplication(processIdentifier: pid)?.isTerminated == false {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
        }
    }

    /// Never erase a placement until observation proves the source has left it.
    @discardableResult
    private func settle(_ identity: WindowIdentity) -> Bool {
        let entry = journal.entries.first { $0.identity == identity }
        switch HandOff.settle(entry, read: WindowPlacer.readForHandOff(identity)) {
        case .nothingJournaled: return true
        case .dropEntry:
            do { try journal.remove(identity); return true }
            catch { onRecoveryRequired?(identity); return false }
        case .keepPlacementAndRecover:
            if var entry {
                entry.handOff = nil
                do { try journal.upsert(entry) }
                catch { NSLog("Dropy hand-off settlement failed: %@", String(describing: error)) }
            }
            onRecoveryRequired?(identity)
            return false
        }
    }
}
