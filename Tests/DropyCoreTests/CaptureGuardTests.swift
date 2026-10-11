import XCTest
import DropyCore

final class CaptureGuardTests: XCTestCase {
    func testPrimeVideoBlocksCaptureAndOtherAppsDoNot() {
        XCTAssertEqual(CaptureGuard.blocker(in: [("com.apple.TextEdit", "TextEdit"),
                                                 ("com.amazon.aiv.AIVApp", "Prime Video")]), "Prime Video")
        XCTAssertNil(CaptureGuard.blocker(in: [("com.apple.Safari", "Safari"), (nil, nil)]))
        XCTAssertEqual(CaptureGuard.blocker(in: [("com.amazon.aiv.AIVApp", nil)]), "A video app")
    }

    func testTheRefusalSaysWhyAndIsNotAPermissionProblem() {
        let failure = CaptureFailure.captureStopsPlayback(applicationName: "Prime Video")
        XCTAssertTrue(failure.message.contains("Prime Video"))
        XCTAssertFalse(failure.opensPrivacySettings)
        XCTAssertFalse(failure.diagnosticName.contains("Prime"), "log names carry no app names")
    }
}
