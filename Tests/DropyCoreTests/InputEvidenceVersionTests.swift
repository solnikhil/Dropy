import Foundation
import XCTest
import DropyCore

/// Support is per app version: an update can change an app's Accessibility tree, event
/// handling or focus behaviour, so evidence never carries over to an untested version.
final class InputEvidenceVersionTests: XCTestCase {
    private let trials = [FocusState.otherWindowKey, .appInactive].map {
        InputTrial(route: .accessibility, kind: .scroll, condition: .visible, focus: $0, outcome: .pass, sideEffects: [])
    }

    private func evidence(_ versions: [String?]) -> InputEvidence {
        InputEvidence(macOS: "27.0", macOSMajor: 27, sources: versions.map {
            .init(bundleIdentifier: "com.example.app", appVersion: $0, report: "r", trials: trials)
        })
    }

    private func grants(_ evidence: InputEvidence, _ version: String?) -> Bool {
        !evidence.capabilities(for: "com.example.app", appVersion: version, macOSMajor: 27)
            .verifiedKinds(in: .visible, policy: .preview).isEmpty
    }

    func testOnlyTheExactTestedVersionIsGranted() {
        let tested = evidence(["1.21"])
        XCTAssertTrue(grants(tested, "1.21"))
        for other in ["1.22", "1.21.1", "1.2", "1.21 ", "2.0"] {
            XCTAssertFalse(grants(tested, other), "version \(other) inherited 1.21's evidence")
        }
        XCTAssertEqual(tested.match(for: "com.example.app", appVersion: "1.22", macOSMajor: 27),
                       .appVersionUntested(running: "1.22", tested: ["1.21"]))
    }

    func testAnUnknownRunningVersionIsRefused() {
        let tested = evidence(["1.21"])
        XCTAssertFalse(grants(tested, nil))
        XCTAssertFalse(grants(tested, ""))
        XCTAssertEqual(tested.match(for: "com.example.app", appVersion: nil, macOSMajor: 27), .appVersionUnknown)
    }

    func testEvidenceWithoutARecordedVersionGrantsNothing() {
        let unversioned = evidence([nil])
        XCTAssertFalse(grants(unversioned, "1.21"))
        XCTAssertFalse(grants(unversioned, nil))
    }

    func testVersionsAreNotPooledAcrossSources() {
        // Two tested versions: each gets only its own trials.
        let failing = [FocusState.otherWindowKey, .appInactive].map {
            InputTrial(route: .accessibility, kind: .scroll, condition: .visible, focus: $0, outcome: .noEffect, sideEffects: [])
        }
        let mixed = InputEvidence(macOS: "27.0", macOSMajor: 27, sources: [
            .init(bundleIdentifier: "com.example.app", appVersion: "1.0", report: "r", trials: trials),
            .init(bundleIdentifier: "com.example.app", appVersion: "2.0", report: "r", trials: failing),
        ])
        XCTAssertTrue(grants(mixed, "1.0"))
        XCTAssertFalse(grants(mixed, "2.0"))
    }

    func testOtherMacOSAndUnknownAppsAreRefused() {
        let tested = evidence(["1.21"])
        XCTAssertEqual(tested.match(for: "com.example.app", appVersion: "1.21", macOSMajor: 28), .otherMacOS(tested: 27))
        XCTAssertEqual(tested.match(for: "com.example.other", appVersion: "1.21", macOSMajor: 27), .noEvidence)
    }

    func testTheViewOnlyLabelSaysWhy() {
        XCTAssertEqual(InteractionLabel.viewOnlyReason(.appVersionUntested(running: "1.22", tested: ["1.21"])),
                       "View only · verified for version 1.21, running 1.22")
        XCTAssertEqual(InteractionLabel.viewOnlyReason(.appVersionUnknown), "View only · app version unknown")
        XCTAssertNil(InteractionLabel.viewOnlyReason(.noEvidence))
    }
}
