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

    func testOnlyPlayersCountNotSoundOrKeepAwakeTools() {
        let display = "PreventUserIdleDisplaySleep"
        let assertions: [Int32: [[String: Any]]] = [
            // Names seen in powerd's log on 2026-10-20.
            10: [["AssertType": display, "AssertName": "com.apple.coremedia.iq.ca.client-1"]], // Prime Video
            11: [["AssertType": "NoDisplaySleepAssertion", "AssertName": "Video Wake Lock"]],  // Helium
            12: [["AssertType": display, "AssertName": "com.apple.WebCore: HTMLMediaElement playback"]],
            // coreaudiod holds one for any app playing or recording sound.
            20: [["AssertType": display, "AssertName": "com.apple.audio.context10236.preventuseridledisplaysleep",
                  "AssertionOnBehalfOfPID": 21]],
            22: [["AssertType": display, "AssertName": "net.whatsapp.idletimer"]],
            23: [["AssertType": display, "AssertName": "Codex Computer Use interaction"]],
        ]
        XCTAssertEqual(CaptureGuard.displayAwakeProcesses(assertions), [10, 11, 12])
    }

    func testTheSettingWinsOverAnythingPlaying() {
        XCTAssertEqual(CaptureGuard.refusal(neverCaptures: true, playing: "Safari"), .captureTurnedOff)
        XCTAssertEqual(CaptureGuard.refusal(neverCaptures: false, playing: "Safari"),
                       .videoPlaying(applicationName: "Safari"))
        XCTAssertNil(CaptureGuard.refusal(neverCaptures: false, playing: nil))
    }

    func testCaptureIsAllowedUnlessTurnedOff() throws {
        let old = try JSONDecoder().decode(DropyPreferences.self, from: Data(#"{"sizePreset":"wide"}"#.utf8))
        XCTAssertFalse(old.protectsVideo)
        var preferences = DropyPreferences()
        preferences.protectsVideo = true
        let round = try JSONDecoder().decode(DropyPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(round.protectsVideo)
    }

    func testAPausedVideoCountsForAWhile() {
        var log = VideoActivityLog()
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(log.observe([], at: start), [])
        XCTAssertNil(log.recent(at: start), "nothing has played")
        XCTAssertEqual(log.observe([2474], at: start), [2474], "playback started")
        XCTAssertEqual(log.observe([2474], at: start.addingTimeInterval(60)), [], "still playing")
        // Paused an hour into the episode: it counts from the pause, not from the start.
        log.observe([], at: start.addingTimeInterval(3600))
        XCTAssertEqual(log.recent(at: start.addingTimeInterval(3600 + 10 * 60)), 2474)
        XCTAssertNil(log.recent(at: start.addingTimeInterval(3600 + 16 * 60)), "long paused")
        XCTAssertNil(log.recent(at: start.addingTimeInterval(3600)) { $0 != 2474 }, "the player quit")
    }
}
