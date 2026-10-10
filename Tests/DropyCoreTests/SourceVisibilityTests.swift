import XCTest
import DropyCore

final class SourceVisibilityTests: XCTestCase {
    func testWindowOnAnotherDisplayIsAvailableDespiteCaptureFlag() {
        XCTAssertEqual(SourceVisibility.resolve(appHidden: false, serverOnScreen: true, captureOnScreen: false), .available)
    }
    func testOnlyConfirmedHiddenStateSaysHidden() {
        XCTAssertEqual(SourceVisibility.resolve(appHidden: true, serverOnScreen: false, captureOnScreen: false), .hidden)
        let unknown = SourceVisibility.resolve(appHidden: false, serverOnScreen: nil, captureOnScreen: false)
        XCTAssertEqual(unknown, .unknown)
        XCTAssertFalse(unknown.message(applicationName: "WhatsApp").contains("hidden"))
        XCTAssertFalse(unknown.message(applicationName: "WhatsApp").contains("minimized"))
    }
    func testOutsideActiveDesktopDoesNotClaimCapturePaused() {
        let visibility = SourceVisibility.resolve(appHidden: false, serverOnScreen: false, captureOnScreen: false)
        XCTAssertEqual(visibility, .notReportedOnScreen)
        XCTAssertFalse(visibility.message(applicationName: "WhatsApp").contains("paused"))
        XCTAssertTrue(CapturePhase.sourceVisibility(applicationName: "WhatsApp", visibility: visibility).isCapturing)
    }
}
