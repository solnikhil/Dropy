import XCTest
import DropyCore

final class CaptureActivityTrackerTests: XCTestCase {
    func testStaticSourceEntersIdleOnlyOnce() {
        var tracker = CaptureActivityTracker(unchangedThreshold: 3)
        XCTAssertNil(tracker.record(unchanged: true))
        XCTAssertNil(tracker.record(unchanged: true))
        XCTAssertEqual(tracker.record(unchanged: true), true)
        XCTAssertNil(tracker.record(unchanged: true))
        XCTAssertTrue(tracker.isIdle)
    }

    func testReconfigurationArtifactDoesNotCauseRateOscillation() {
        var tracker = CaptureActivityTracker(unchangedThreshold: 2)
        _ = tracker.record(unchanged: true)
        _ = tracker.record(unchanged: true)
        for _ in 0..<20 {
            XCTAssertNil(tracker.record(unchanged: false))
            XCTAssertNil(tracker.record(unchanged: true))
            XCTAssertTrue(tracker.isIdle)
        }
    }

    func testSustainedAnimationReturnsToFullRate() {
        var tracker = CaptureActivityTracker(unchangedThreshold: 2)
        _ = tracker.record(unchanged: true)
        _ = tracker.record(unchanged: true)
        XCTAssertNil(tracker.record(unchanged: false))
        XCTAssertEqual(tracker.record(unchanged: false), false)
        XCTAssertFalse(tracker.isIdle)
        XCTAssertNil(tracker.record(unchanged: false))
        XCTAssertNil(tracker.record(unchanged: true))
        XCTAssertEqual(tracker.record(unchanged: true), true)
    }
}
