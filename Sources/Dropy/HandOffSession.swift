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

    private(set) var active: Active?
    private var starting = false
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
        guard active == nil, !starting else { return .ignored }
        starting = true
        defer { starting = false }
        let entry = journal.entries.first { $0.identity == identity }
        let plan: HandOff.Start
        switch HandOff.start(trigger: trigger, entry: entry,
                             current: (try? WindowPlacer.state(of: identity)) ?? nil,
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
                // Ending it undoes the hand-off by the same rules: the window did not
                // reach the expected state, so nothing is re-parked, and the record goes.
                end(reason: "restoreFailed")
                return .failed(String(describing: error))
            }
        }
        // The window is the person's again: no tab may cover it, it comes to the front of
        // its own app, and that app comes to the front.
        onRestored?(identity)
        do { try WindowPlacer.raise(identity) }
        catch { NSLog("Dropy hand-off raise failed: %@", String(describing: error)) }
        NSRunningApplication(processIdentifier: identity.processID)?.activate()
        NSLog("Dropy hand-off started: window=%u restored=%@ repark=%@ returnFocus=%@",
              identity.windowID, plan.restoreTo == nil ? "no" : "yes",
              plan.reparkMode?.rawValue ?? "none", plan.returnFocusTo.map(String.init) ?? "none")
        return .started
    }

    /// Ends the hand-off from the state at this moment. `HandOff.end` alone decides whether
    /// the window is re-parked and where focus goes; nothing here may add to that.
    func end(reason: String) {
        guard let active else { return }
        self.active = nil
        let identity = active.identity
        let returnApp = active.plan.returnFocusTo.flatMap { NSRunningApplication(processIdentifier: $0) }
        let decision = HandOff.end(active.plan,
                                   current: (try? WindowPlacer.state(of: identity)) ?? nil,
                                   frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                   source: identity.processID,
                                   returnAppRunning: returnApp?.isTerminated == false)
        // The record goes before anything moves: a crash from here on finds no hand-off,
        // and the window it would have found is on screen where the person left it.
        var recordCleared = true
        if journal.entries.contains(where: { $0.identity == identity && $0.handOff != nil }) {
            do { try journal.remove(identity) }
            catch {
                recordCleared = false
                NSLog("Dropy hand-off journal clear failed: %@", String(describing: error))
            }
        }
        NSLog("Dropy hand-off ended: reason=%@ window=%u repark=%@ activate=%@", reason, identity.windowID,
              decision.repark?.rawValue ?? "none", decision.activate.map(String.init) ?? "none")
        onChange?()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A re-park is a fresh placement with its own write-ahead record. Without a
            // cleared record it would be refused as a pending placement, so skip it and
            // leave the window reachable rather than half-recorded.
            if let mode = decision.repark, recordCleared {
                do { self.onReparked?(try await WindowPlacer.apply(mode, to: identity, journal: self.journal)) }
                catch { NSLog("Dropy hand-off repark failed: %@", String(describing: error)) }
            }
            if let pid = decision.activate { NSRunningApplication(processIdentifier: pid)?.activate() }
        }
    }
}
