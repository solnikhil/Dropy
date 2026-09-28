import CoreGraphics
import Foundation
import XCTest
import DropyCore

final class SourceRecoveryTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    private let identity = WindowIdentity(processID: 7, processLaunchDate: Date(timeIntervalSince1970: 1),
                                          windowID: 99, bundleIdentifier: "org.dropy.fixture")

    private func facts(ids: [UInt32?] = [], roles: [String] = [], listed: Bool = true, onScreen: Bool = true,
                       spaces: [UInt64]? = [1], active: [UInt64]? = [1]) -> WindowLookupFacts {
        WindowLookupFacts(trusted: true, processRunning: true, listedRoles: roles, candidateWindowIDs: ids,
                          windowServerListed: listed, windowServerOnScreen: onScreen,
                          windowSpaces: spaces, activeSpaces: active)
    }

    private func parked(confirmed: Bool? = true, mode: PlacementMode = .parked) -> PlacementEntry {
        let original = WindowPlacementState(frame: CGRect(x: 80, y: 560, width: 800, height: 440),
                                            isMinimized: false, isAppHidden: false)
        var applied = original
        switch mode {
        case .minimize: applied.isMinimized = true
        case .hideApp: applied.isAppHidden = true
        case .offscreen, .parked: applied.frame.origin = CGPoint(x: 1670, y: 994)
        }
        return PlacementEntry(identity: identity, mode: mode, original: original, applied: applied,
                              createdAt: Date(timeIntervalSince1970: 2), applicationConfirmed: confirmed)
    }

    // The failure seen on device: the app's windows list was empty because the window's
    // Space was not active, while the window server still listed it.
    func testWindowOnAnotherSpaceIsDiagnosedAsSuchNotAsGone() {
        let diagnosis = WindowLookupDiagnosis.diagnose(
            facts(ids: [], onScreen: false, spaces: [4], active: [1]), windowID: 99)
        XCTAssertEqual(diagnosis, .onOtherSpace)
        XCTAssertTrue(diagnosis.mayBecomeReachable)
        // Main or focused window matching the exact ID means it was found.
        XCTAssertEqual(WindowLookupDiagnosis.diagnose(
            facts(ids: [99], onScreen: false, spaces: [4], active: [1]), windowID: 99), .found)
    }

    func testEachCauseIsDistinguished() {
        func diagnose(_ facts: WindowLookupFacts) -> WindowLookupDiagnosis {
            WindowLookupDiagnosis.diagnose(facts, windowID: 99)
        }
        var untrusted = facts(); untrusted.trusted = false
        XCTAssertEqual(diagnose(untrusted), .accessibilityNotTrusted)
        var exited = facts(); exited.processRunning = false
        XCTAssertEqual(diagnose(exited), .processGone)
        var disabled = facts(); disabled.windowsListError = -25211
        XCTAssertEqual(diagnose(disabled), .accessibilityDisabled)
        var busy = facts(); busy.windowsListError = -25204
        XCTAssertEqual(diagnose(busy), .appNotResponding(axError: -25204))
        busy.windowServerListed = false
        XCTAssertEqual(diagnose(busy), .appNotResponding(axError: -25204))
        XCTAssertEqual(RestorePlan.make(for: parked(), read: .unreachable(diagnose(busy)), displays: [main]),
                       .deferral(.windowUnreachable(.appNotResponding(axError: -25204))))
        XCTAssertEqual(diagnose(facts(listed: false)), .windowClosed)
        var serverUnavailable = facts(listed: false)
        serverUnavailable.windowServerQuerySucceeded = false
        XCTAssertEqual(diagnose(serverUnavailable), .windowServerUnavailable)
        XCTAssertEqual(RestorePlan.make(for: parked(), read: .unreachable(diagnose(serverUnavailable)), displays: [main]),
                       .deferral(.windowUnreachable(.windowServerUnavailable)))
        XCTAssertEqual(diagnose(facts(ids: [nil], roles: ["AXScrollArea"])), .nonWindowElements)
        XCTAssertEqual(diagnose(facts(ids: [nil], roles: ["AXWindow"])), .lookupFailed)
        var stale = facts(ids: [12], roles: ["AXWindow"]); stale.staleCandidates = 1
        XCTAssertEqual(diagnose(stale), .staleElements)
        XCTAssertEqual(diagnose(facts(ids: [12], roles: ["AXWindow"])), .unlisted)
        // Without Space facts, an off-screen window is reported as such rather than guessed.
        XCTAssertEqual(diagnose(facts(onScreen: false, spaces: nil, active: nil)), .notOnScreen)
        // A window on every Space (e.g. sticky) overlapping the active one is not "other Space".
        XCTAssertEqual(diagnose(facts(ids: [12], roles: ["AXWindow"], spaces: [1, 4], active: [4])), .unlisted)
        XCTAssertFalse(WindowLookupDiagnosis.windowClosed.mayBecomeReachable)
        XCTAssertFalse(WindowLookupDiagnosis.processGone.mayBecomeReachable)
    }

    func testUnreachableWindowKeepsItsRecoveryRecord() {
        let entry = parked()
        for diagnosis in [WindowLookupDiagnosis.onOtherSpace, .notOnScreen, .appNotResponding(axError: -25204),
                          .nonWindowElements, .lookupFailed, .staleElements, .unlisted, .accessibilityDisabled, .windowServerUnavailable] {
            XCTAssertEqual(RestorePlan.make(for: entry, read: .unreachable(diagnosis), displays: [main]),
                           .deferral(.windowUnreachable(diagnosis)), "\(diagnosis)")
        }
        XCTAssertEqual(RestorePlan.make(for: entry, read: .unreachable(.accessibilityNotTrusted), displays: [main]),
                       .deferral(.accessibilityNotTrusted))
        XCTAssertEqual(RestorePlan.make(for: entry, read: .failed("attribute(AXPosition,-25204)"), displays: [main]),
                       .deferral(.readFailed("attribute(AXPosition,-25204)")))
    }

    func testOnlyAClosedWindowOrExitedProcessSettlesAsGone() {
        let entry = parked()
        XCTAssertEqual(RestorePlan.make(for: entry, read: .unreachable(.windowClosed), displays: [main]),
                       .settle(.sourceGone))
        XCTAssertEqual(RestorePlan.make(for: entry, read: .unreachable(.processGone), displays: [main]),
                       .settle(.sourceGone))
    }

    func testReachableWindowIsRestoredOrLeftToTheUser() {
        let entry = parked()
        XCTAssertEqual(RestorePlan.make(for: entry, read: .state(entry.applied), displays: [main]),
                       .restore(.restore(entry.original), unhide: false, unminimize: false,
                                frame: entry.original.frame, resize: false))
        var moved = entry.applied
        moved.frame.origin = CGPoint(x: 200, y: 200)
        XCTAssertEqual(RestorePlan.make(for: entry, read: .state(moved), displays: [main]), .settle(.keepUserChange))
        // An unconfirmed, clamped move stays for the person's explicit choice.
        let unconfirmed = parked(confirmed: false)
        var clamped = unconfirmed.applied
        clamped.frame.origin.x -= 10
        XCTAssertEqual(RestorePlan.make(for: unconfirmed, read: .state(clamped), displays: [main]), .settle(.pending))
        XCTAssertFalse(RestoreOutcome.decided(.pending).retriesAutomatically)
        XCTAssertTrue(RestoreOutcome.deferred(.windowUnreachable(.onOtherSpace)).retriesAutomatically)
    }

    func testMinimizeAndHideRestorePlans() {
        let minimized = parked(mode: .minimize)
        XCTAssertEqual(RestorePlan.make(for: minimized, read: .state(minimized.applied), displays: [main]),
                       .restore(.restore(minimized.original), unhide: false, unminimize: true,
                                frame: minimized.original.frame, resize: false))
        // Hiding changed only the app, so the window itself is left alone.
        let hidden = parked(mode: .hideApp)
        XCTAssertEqual(RestorePlan.make(for: hidden, read: .state(hidden.applied), displays: [main]),
                       .restore(.restore(hidden.original), unhide: true, unminimize: false, frame: nil, resize: false))
    }

    func testPartialRestoreNeverSettlesAsAUserMove() {
        var interrupted = parked(mode: .minimize)
        interrupted.applicationConfirmed = false
        var partiallyRestored = interrupted.applied
        partiallyRestored.isMinimized = false
        partiallyRestored.frame.origin.x += 20 // system repositioned during unminimize
        XCTAssertEqual(RestorePlan.make(for: interrupted, read: .state(partiallyRestored), displays: [main]),
                       .settle(.pending))
        // A failed write that changed nothing can still be retried safely.
        XCTAssertEqual(RestorePlan.make(for: interrupted, read: .state(interrupted.applied), displays: [main]),
                       .restore(.restore(interrupted.original), unhide: false, unminimize: true,
                                frame: interrupted.original.frame, resize: false))
    }

    func testAdviceNamesTheSpaceAndPermissionCases() {
        XCTAssertTrue(RestoreDeferral.windowUnreachable(.onOtherSpace).advice.contains("desktop"))
        XCTAssertTrue(RestoreDeferral.accessibilityNotTrusted.advice.contains("Accessibility"))
        XCTAssertEqual(RestoreDeferral.windowUnreachable(.onOtherSpace).description, "windowUnreachable(onOtherSpace)")
    }

    func testBackoffGrowsToThirtySeconds() {
        XCTAssertEqual((0...6).map(RecoveryBackoff.delay(afterAttempt:)), [1, 2, 4, 8, 16, 30, 30])
        XCTAssertEqual(RecoveryBackoff.delay(afterAttempt: 1_000), 30)
        XCTAssertEqual(RecoveryBackoff.delay(afterAttempt: -1), 1)
    }
}
