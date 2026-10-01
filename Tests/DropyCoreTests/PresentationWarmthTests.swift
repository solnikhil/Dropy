import Foundation
import XCTest
import DropyCore

final class PresentationWarmthTests: XCTestCase {
    func testInputWarmsLongEnoughToCoverTheMeasuredInputToPresentPath() {
        var warmth = PresentationWarmth()
        XCTAssertFalse(warmth.isWarm(at: 10))
        warmth.noteInput(at: 10)
        XCTAssertTrue(warmth.isWarm(at: 10))
        // Input to captured frame measured 64–75 ms at p50, then draw and compose.
        XCTAssertTrue(warmth.isWarm(at: 10.075))
        XCTAssertTrue(warmth.isWarm(at: 10.15))
        XCTAssertFalse(warmth.isWarm(at: 10.36))
        // The deadline itself is already cold: warmth covers up to it, not through it.
        let deadline = warmth.warmUntil!
        XCTAssertEqual(deadline, 10.35, accuracy: 1e-9)
        XCTAssertFalse(warmth.isWarm(at: deadline))
        XCTAssertNil(warmth.remaining(at: deadline))
        XCTAssertEqual(warmth.remaining(at: 10.1)!, 0.25, accuracy: 1e-9)
    }

    func testTheFirstFrameAndAFrameAfterAQuietGapAreColdAndWarmThePath() {
        var warmth = PresentationWarmth()
        // The cold reveal: no previous frame at all.
        XCTAssertTrue(warmth.noteFrame(at: 1))
        XCTAssertTrue(warmth.isWarm(at: 1.1))
        // A source changing at the idle 10 fps rate is not a wake.
        XCTAssertFalse(warmth.noteFrame(at: 1.1))
        XCTAssertFalse(warmth.noteFrame(at: 1.2))
        // A clear gap is.
        XCTAssertTrue(warmth.noteFrame(at: 1.5))
        XCTAssertEqual(warmth.warmUntil!, 1.7, accuracy: 1e-9)
        XCTAssertTrue(warmth.isWarm(at: 1.65))
        XCTAssertFalse(warmth.isWarm(at: 1.75))
    }

    func testTheColdGapBoundaryIsInclusiveSoAGapOfExactlyTheGapIsAWake() {
        var warmth = PresentationWarmth()
        warmth.noteFrame(at: 0)
        XCTAssertTrue(warmth.noteFrame(at: warmth.coldGap))
        warmth.cool()
        warmth.noteFrame(at: 0)
        XCTAssertFalse(warmth.noteFrame(at: warmth.coldGap.nextDown))
    }

    func testFrameCadenceAtSixtyAndAtTenPerSecondNeverCountsAsAWake() {
        var warmth = PresentationWarmth()
        warmth.noteFrame(at: 0)
        var time = 0.0
        for _ in 0..<120 {
            time += 1.0 / 60
            XCTAssertFalse(warmth.noteFrame(at: time))
        }
        for _ in 0..<20 {
            time += 0.1
            XCTAssertFalse(warmth.noteFrame(at: time))
        }
    }

    func testAReportedMissWarmsThePathForTheRedrawThatFollows() {
        var warmth = PresentationWarmth()
        warmth.noteFrame(at: 5)
        warmth.noteDrawableMiss(at: 5.3)
        XCTAssertEqual(warmth.warmUntil!, 5.55, accuracy: 1e-9)
        XCTAssertTrue(warmth.isWarm(at: 5.5))
        XCTAssertFalse(warmth.isWarm(at: 5.6))
    }

    func testWarmthOnlyEverExtendsForwardAndNeverShortensAnActiveWindow() {
        var warmth = PresentationWarmth()
        warmth.noteInput(at: 100)
        XCTAssertEqual(warmth.warmUntil!, 100.35, accuracy: 1e-9)
        // A shorter stimulus inside a longer window must not cut it short.
        warmth.noteDrawableMiss(at: 100.01)
        XCTAssertEqual(warmth.warmUntil!, 100.35, accuracy: 1e-9)
        warmth.noteFrame(at: 100.02)
        XCTAssertEqual(warmth.warmUntil!, 100.35, accuracy: 1e-9)
        // A later stimulus does extend it.
        warmth.noteDrawableMiss(at: 100.3)
        XCTAssertEqual(warmth.warmUntil!, 100.55, accuracy: 1e-9)
    }

    func testWarmthAlwaysExpiresSoAQuietPreviewStopsDoingPeriodicWork() {
        var warmth = PresentationWarmth()
        warmth.noteInput(at: 0)
        warmth.noteFrame(at: 0.07)
        warmth.noteDrawableMiss(at: 0.09)
        // Nothing further happens: the longest window from the last stimulus decides.
        let deadline = warmth.warmUntil!
        XCTAssertEqual(deadline, 0.35, accuracy: 1e-9)
        XCTAssertFalse(warmth.isWarm(at: deadline))
        XCTAssertNil(warmth.remaining(at: deadline))
    }

    func testClearingCoolsAtOnceSoAClosedOverlayCannotLeaveTheLinkRunning() {
        var warmth = PresentationWarmth()
        warmth.noteInput(at: 20)
        XCTAssertTrue(warmth.isWarm(at: 20.1))
        warmth.cool()
        XCTAssertFalse(warmth.isWarm(at: 20.1))
        XCTAssertNil(warmth.warmUntil)
        // After cooling, the next frame is the first of a session again.
        XCTAssertTrue(warmth.noteFrame(at: 20.11))
    }

    func testAClockThatWentBackwardsIsIgnoredRatherThanReadAsWarm() {
        var warmth = PresentationWarmth()
        warmth.noteFrame(at: 50)
        XCTAssertFalse(warmth.noteFrame(at: 49))
        // The good timestamp still decides the next gap.
        XCTAssertFalse(warmth.noteFrame(at: 50.1))
        XCTAssertTrue(warmth.noteFrame(at: 50.4))
    }

    func testCustomWindowsAndColdGapAreHonoured() {
        var warmth = PresentationWarmth(
            windows: .init(afterInput: 1, afterColdFrame: 0.5, afterMiss: 0.25), coldGap: 0.05)
        warmth.noteInput(at: 0)
        XCTAssertTrue(warmth.isWarm(at: 0.99))
        XCTAssertFalse(warmth.isWarm(at: 1))
        warmth.cool()
        warmth.noteFrame(at: 2)
        XCTAssertFalse(warmth.noteFrame(at: 2.03))
        XCTAssertTrue(warmth.noteFrame(at: 2.13))
        XCTAssertEqual(warmth.warmUntil!, 2.63, accuracy: 1e-9)
        XCTAssertTrue(warmth.isWarm(at: 2.6))
        XCTAssertFalse(warmth.isWarm(at: 2.7))
    }
}
