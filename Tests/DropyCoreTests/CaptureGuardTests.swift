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

    func testTheSettingWinsThenKnownPlayersThenAnythingPlaying() {
        XCTAssertEqual(CaptureGuard.refusal(neverCaptures: true, stopsPlayback: "Prime Video", playing: "Safari"),
                       .captureTurnedOff)
        XCTAssertEqual(CaptureGuard.refusal(neverCaptures: false, stopsPlayback: "Prime Video", playing: "Safari"),
                       .captureStopsPlayback(applicationName: "Prime Video"))
        XCTAssertEqual(CaptureGuard.refusal(neverCaptures: false, stopsPlayback: nil, playing: "Safari"),
                       .videoPlaying(applicationName: "Safari"))
        XCTAssertNil(CaptureGuard.refusal(neverCaptures: false, stopsPlayback: nil, playing: nil))
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
