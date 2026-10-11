import XCTest
import DropyCore

final class CaptureGuardTests: XCTestCase {
    func testTheRefusalSaysWhyAndCanBeOverruled() {
        let failure = CaptureFailure.videoPlaying(applicationName: "Safari")
        XCTAssertTrue(failure.message.contains("Safari"))
        XCTAssertFalse(failure.opensPrivacySettings)
        XCTAssertFalse(failure.diagnosticName.contains("Safari"), "log names carry no app names")
        XCTAssertEqual(failure.actionTitle, "Show Anyway")
        XCTAssertEqual(CaptureFailure.permissionDenied.actionTitle, "Open Privacy Settings")
        XCTAssertNil(CaptureFailure.captureTurnedOff.actionTitle, "the person's own setting is not overruled")
    }

    func testDisplayAwakeProcessesAreTheOnesKeepingTheScreenOn() {
        let assertions: [Int32: [[String: Any]]] = [
            // caffeinate and other system-sleep holds leave the display alone.
            92705: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "caffeinate"]],
            700: [["AssertType": "PreventUserIdleDisplaySleep", "AssertName": "Video Wake Lock"]],
            // runningboardd holding one for an app counts for that app.
            418: [["AssertType": "NoDisplaySleepAssertion", "AssertionOnBehalfOfPID": 701]],
            900: [["AssertType": "PreventUserIdleDisplaySleep"]],
        ]
        XCTAssertEqual(CaptureGuard.displayAwakeProcesses(assertions, excluding: [900]), [701, 700])
        XCTAssertEqual(CaptureGuard.displayAwakeProcesses([:]), [])
    }

    func testTheSettingWinsOverAnythingPlaying() {
        XCTAssertEqual(CaptureGuard.refusal(neverCaptures: true, playing: "Safari"), .captureTurnedOff)
        XCTAssertEqual(CaptureGuard.refusal(neverCaptures: false, playing: "Safari"),
                       .videoPlaying(applicationName: "Safari"))
        XCTAssertNil(CaptureGuard.refusal(neverCaptures: false, playing: nil))
    }

    func testCaptureIsAllowedUnlessTurnedOff() throws {
        let old = try JSONDecoder().decode(DropyPreferences.self, from: Data(#"{"sizePreset":"wide"}"#.utf8))
        XCTAssertFalse(old.neverCapturesScreen)
        var preferences = DropyPreferences()
        preferences.neverCapturesScreen = true
        let round = try JSONDecoder().decode(DropyPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(round.neverCapturesScreen)
    }
}
