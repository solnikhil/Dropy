import Foundation
import XCTest
import DropyCore

final class PresentationModeTests: XCTestCase {
    func testAnAbsentOrEmptyRequestKeepsTheMeasuredBaseline() {
        XCTAssertEqual(PresentationMode.resolve([:]).mode, .retry)
        XCTAssertEqual(PresentationMode.resolve([:]).unrecognized, nil)
        XCTAssertEqual(PresentationMode.resolve(["DROPY_PRESENT_MODE": ""]).mode, .retry)
        XCTAssertEqual(PresentationMode.resolve(["DROPY_PRESENT_MODE": "  "]).mode, .retry)
        XCTAssertEqual(PresentationMode.resolve(["DROPY_PRESENT_MODE": "  "]).unrecognized, "  ")
        XCTAssertEqual(PresentationMode.measuredDefault, .retry)
    }

    func testEveryModeIsSelectableByNameAndSurroundingSpaceOrCaseDoesNotMatter() {
        for mode in PresentationMode.allCases {
            XCTAssertEqual(PresentationMode.resolve(["DROPY_PRESENT_MODE": mode.rawValue]).mode, mode)
            XCTAssertEqual(PresentationMode.resolve(["DROPY_PRESENT_MODE": " \(mode.rawValue.uppercased())\n"]).mode,
                           mode)
        }
        XCTAssertEqual(PresentationMode.resolve(["DROPY_PRESENT_MODE": "warm-transaction"]).mode, .warmTransaction)
    }

    func testAnUnknownRequestIsReportedAndNeverSilentlyEnablesAnExperiment() {
        let resolution = PresentationMode.resolve(["DROPY_PRESENT_MODE": "wam"])
        XCTAssertEqual(resolution.mode, .retry)
        XCTAssertEqual(resolution.unrecognized, "wam")
        // A near miss must not be read as the mode it resembles.
        XCTAssertFalse(resolution.mode.keepsDisplayLinkWarm)
        XCTAssertFalse(resolution.mode.presentsWithTransaction)
    }

    func testEachModeEnablesExactlyThePathsItNames() {
        XCTAssertFalse(PresentationMode.retry.keepsDisplayLinkWarm)
        XCTAssertFalse(PresentationMode.retry.presentsWithTransaction)
        XCTAssertTrue(PresentationMode.warm.keepsDisplayLinkWarm)
        XCTAssertFalse(PresentationMode.warm.presentsWithTransaction)
        XCTAssertFalse(PresentationMode.transaction.keepsDisplayLinkWarm)
        XCTAssertTrue(PresentationMode.transaction.presentsWithTransaction)
        XCTAssertTrue(PresentationMode.warmTransaction.keepsDisplayLinkWarm)
        XCTAssertTrue(PresentationMode.warmTransaction.presentsWithTransaction)
        // The redraw-after-miss fallback also covers a covered or opening panel, so no
        // mode may drop it.
        for mode in PresentationMode.allCases { XCTAssertTrue(mode.retriesAfterDrawableMiss) }
    }
}
