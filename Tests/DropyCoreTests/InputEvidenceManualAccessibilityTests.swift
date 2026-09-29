import Foundation
import XCTest
import DropyCore

final class InputEvidenceManualAccessibilityTests: XCTestCase {
    func testOlderEvidenceWithoutTheFieldStillDecodesAndNeedsNothing() throws {
        let json = #"{"format":1,"macOS":"27.0","macOSMajor":27,"sources":[{"bundleIdentifier":"a","report":"r","trials":[]}]}"#
        let evidence = try JSONDecoder().decode(InputEvidence.self, from: Data(json.utf8))
        XCTAssertFalse(evidence.requiresManualAccessibility(for: "a", macOSMajor: 27))
    }

    func testOnlyTheRecordedAppOnTheTestedMacOSNeedsIt() {
        let evidence = InputEvidence(macOS: "27.0", macOSMajor: 27, sources: [
            .init(bundleIdentifier: "electron", appVersion: nil, report: "r", trials: [], requiresManualAccessibility: true),
            .init(bundleIdentifier: "appkit", appVersion: nil, report: "r", trials: [])
        ])
        XCTAssertTrue(evidence.requiresManualAccessibility(for: "electron", macOSMajor: 27))
        XCTAssertFalse(evidence.requiresManualAccessibility(for: "appkit", macOSMajor: 27))
        XCTAssertFalse(evidence.requiresManualAccessibility(for: "electron", macOSMajor: 28))
        XCTAssertFalse(evidence.requiresManualAccessibility(for: nil, macOSMajor: 27))
    }
}
