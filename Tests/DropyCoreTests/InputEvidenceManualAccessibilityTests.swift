import Foundation
import XCTest
import DropyCore

final class InputEvidenceManualAccessibilityTests: XCTestCase {
    func testOlderEvidenceWithoutTheFieldStillDecodesAndNeedsNothing() throws {
        let json = #"{"format":1,"macOS":"27.0","macOSMajor":27,"sources":[{"bundleIdentifier":"a","report":"r","trials":[]}]}"#
        let evidence = try JSONDecoder().decode(InputEvidence.self, from: Data(json.utf8))
        XCTAssertFalse(evidence.requiresManualAccessibility(for: "a", appVersion: "1", macOSMajor: 27))
    }

    func testOnlyTheRecordedAppOnTheTestedMacOSNeedsIt() {
        let evidence = InputEvidence(macOS: "27.0", macOSMajor: 27, sources: [
            .init(bundleIdentifier: "electron", appVersion: "43.2.0", report: "r", trials: [], requiresManualAccessibility: true),
            .init(bundleIdentifier: "appkit", appVersion: "1.0", report: "r", trials: [])
        ])
        XCTAssertTrue(evidence.requiresManualAccessibility(for: "electron", appVersion: "43.2.0", macOSMajor: 27))
        XCTAssertFalse(evidence.requiresManualAccessibility(for: "electron", appVersion: "44.0.0", macOSMajor: 27))
        XCTAssertFalse(evidence.requiresManualAccessibility(for: "appkit", appVersion: "1.0", macOSMajor: 27))
        XCTAssertFalse(evidence.requiresManualAccessibility(for: "electron", appVersion: "43.2.0", macOSMajor: 28))
        XCTAssertFalse(evidence.requiresManualAccessibility(for: nil, appVersion: "43.2.0", macOSMajor: 27))
    }
}
