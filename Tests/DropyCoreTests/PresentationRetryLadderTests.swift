import Foundation
import XCTest
import DropyCore

final class PresentationRetryLadderTests: XCTestCase {
    func testTheDefaultScheduleIsTheOneTheLatencyTraceWasMeasuredWith() {
        var ladder = PresentationRetryLadder()
        // One refresh, then doubling, then held at the cap.
        let expected = [16, 32, 64, 128, 256, 512, 1_000, 1_000, 1_000]
        XCTAssertEqual((0..<expected.count).map { ladder.delayMilliseconds(forSchedule: $0) }, expected)
        XCTAssertEqual((0..<expected.count).map { _ in ladder.nextDelayMilliseconds() }, expected)
        XCTAssertEqual(ladder.scheduledCount, expected.count)
    }

    func testTheFirstThreeAttemptsAlsoRedrawThroughAppKitAndLaterOnesDoNot() {
        let ladder = PresentationRetryLadder()
        XCTAssertFalse(ladder.redrawsImmediately(attempt: 0))
        XCTAssertTrue(ladder.redrawsImmediately(attempt: 1))
        XCTAssertTrue(ladder.redrawsImmediately(attempt: 2))
        XCTAssertTrue(ladder.redrawsImmediately(attempt: 3))
        XCTAssertFalse(ladder.redrawsImmediately(attempt: 4))
        XCTAssertFalse(ladder.redrawsImmediately(attempt: 40))
    }

    func testResetStartsTheFastRedrawAgainForANewFrame() {
        var ladder = PresentationRetryLadder()
        _ = ladder.nextDelayMilliseconds()
        _ = ladder.nextDelayMilliseconds()
        XCTAssertEqual(ladder.nextDelayMilliseconds(), 64)
        ladder.reset()
        XCTAssertEqual(ladder.scheduledCount, 0)
        XCTAssertEqual(ladder.nextDelayMilliseconds(), 16)
    }

    func testTheDelayNeverExceedsTheCapOrOverflowsHoweverManyRedrawsHappen() {
        let ladder = PresentationRetryLadder()
        for index in [0, 1, 7, 64, 1_000, Int.max] {
            let delay = ladder.delayMilliseconds(forSchedule: index)
            XCTAssertTrue(delay >= ladder.firstDelayMilliseconds)
            XCTAssertTrue(delay <= ladder.capMilliseconds)
        }
        XCTAssertEqual(ladder.delayMilliseconds(forSchedule: Int.max), 1_000)
        // A negative index is the first redraw, not a negative sleep.
        XCTAssertEqual(ladder.delayMilliseconds(forSchedule: -5), 16)
    }

    func testTheScheduleIsMonotonicSoARetryNeverGetsFasterThanTheOneBefore() {
        let ladder = PresentationRetryLadder()
        var previous = 0
        for index in 0..<20 {
            let delay = ladder.delayMilliseconds(forSchedule: index)
            XCTAssertTrue(delay >= previous)
            previous = delay
        }
    }

    func testACustomLadderKeepsItsOwnFirstDelayCapAndImmediateCount() {
        var ladder = PresentationRetryLadder(firstDelayMilliseconds: 8, capMilliseconds: 33,
                                             immediateRedraws: 1)
        XCTAssertEqual((0..<5).map { _ in ladder.nextDelayMilliseconds() }, [8, 16, 32, 33, 33])
        XCTAssertTrue(ladder.redrawsImmediately(attempt: 1))
        XCTAssertFalse(ladder.redrawsImmediately(attempt: 2))
    }

    func testALadderWithNoImmediateRedrawsOnlyEverUsesTheTimedSchedule() {
        let ladder = PresentationRetryLadder(immediateRedraws: 0)
        XCTAssertFalse(ladder.redrawsImmediately(attempt: 1))
        XCTAssertEqual(ladder.delayMilliseconds(forSchedule: 0), 16)
    }
}
