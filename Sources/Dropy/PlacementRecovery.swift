import AppKit
import DropyCore

/// Keeps trying to restore journaled source windows until each outcome is final.
///
/// A restore can be deferred for reasons that clear on their own: the window is on a
/// Space that is not active (its app then omits it from the Accessibility tree), the
/// app is busy, or Accessibility was switched off. Retries back off from 1 to 30
/// seconds, and run at once when the active Space changes, an app activates or the
/// Mac wakes, since those are the moments a deferred window becomes reachable.
/// An unconfirmed move (`.pending`) is never retried automatically: it needs the
/// person's choice in "Recover pending source windows…".
@MainActor
final class PlacementRecovery {
    /// Called when an entry is settled and its window no longer needs Dropy.
    var onSettled: ((WindowIdentity) -> Void)?
    /// The latest reason each deferred entry is still waiting.
    private(set) var deferred: [(entry: PlacementEntry, reason: RestoreDeferral)] = []
    private let journal: PlacementJournal
    /// Loaded records are orphaned; new placements remain active until recovery is requested.
    private var requested: Set<WindowIdentity>
    private var attempt = 0
    private var scheduled: Task<Void, Never>?
    private var observers: [NotificationObservation] = []
    private var screenObserver: NotificationObservation?

    init(journal: PlacementJournal) {
        self.journal = journal
        requested = Set(journal.entries.map(\.identity))
    }

    /// Starts listening for Space, activation and wake changes, then tries once.
    func start() {
        guard observers.isEmpty, screenObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NotificationObservation(center: center, forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.requested.isEmpty else { return }
                    self.run(resetBackoff: true)
                }
            })
        }
        screenObserver = NotificationObservation(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.requested.isEmpty else { return }
                    self.run(resetBackoff: true)
                }
            }
        run(resetBackoff: true)
    }

    func stop() {
        observers = []
        screenObserver = nil
        scheduled?.cancel()
        scheduled = nil
    }

    /// Marks a failed restore as eligible for automatic retries. Active placements
    /// are journaled too, but must not be undone by another window's retry.
    func requestRecovery(for identity: WindowIdentity) {
        requested.insert(identity)
        schedule()
    }

    /// Manual recovery explicitly includes current placements.
    @discardableResult
    func recoverAll() -> [(entry: PlacementEntry, outcome: RestoreOutcome)] {
        requested.formUnion(journal.entries.map(\.identity))
        return run(resetBackoff: true)
    }

    /// Tries only orphaned or explicitly requested entries, then schedules deferred ones.
    @discardableResult
    func run(resetBackoff: Bool = false) -> [(entry: PlacementEntry, outcome: RestoreOutcome)] {
        if resetBackoff { attempt = 0 }
        scheduled?.cancel()
        scheduled = nil
        guard journal.loadError == nil, !journal.entries.isEmpty else {
            deferred = []
            return []
        }
        requested.formIntersection(journal.entries.map(\.identity))
        let results = journal.restoreAll(identities: requested)
        for result in results {
            if case .decided = result.outcome { requested.remove(result.entry.identity) }
        }
        deferred = results.compactMap { result in
            if case .deferred(let reason) = result.outcome { return (result.entry, reason) }
            return nil
        }
        for result in results where !journal.entries.contains(where: { $0.identity == result.entry.identity }) {
            onSettled?(result.entry.identity)
        }
        if !deferred.isEmpty { schedule() }
        return results
    }

    /// Schedules a retry after the current backoff, e.g. after one restore was deferred.
    func schedule() {
        guard scheduled == nil, !requested.isEmpty else { return }
        let delay = RecoveryBackoff.delay(afterAttempt: attempt)
        attempt += 1
        scheduled = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.scheduled = nil
            self.run()
        }
    }
}
