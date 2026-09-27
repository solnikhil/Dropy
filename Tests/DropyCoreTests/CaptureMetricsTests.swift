import Foundation
import XCTest
import DropyCore

final class CaptureMetricsTests: XCTestCase {
    func testNearestRankPercentiles() {
        let summary = LatencySummary((1...100).map(Double.init))
        XCTAssertEqual(summary?.p50, 50)
        XCTAssertEqual(summary?.p95, 95)
        XCTAssertEqual(summary?.p99, 99)
        XCTAssertEqual(summary?.max, 100)
        XCTAssertEqual(LatencySummary([7])?.p99, 7)
        XCTAssertNil(LatencySummary([]))
    }

    func testClockDomainsMustAgreeBeforePercentilesAreReported() {
        let plausible = Array(repeating: 20.0, count: 200)
        XCTAssertTrue(ClockDomainCheck.accepts(offsetMilliseconds: 0.2, intervals: plausible))
        XCTAssertFalse(ClockDomainCheck.accepts(offsetMilliseconds: 5, intervals: plausible))
        XCTAssertFalse(ClockDomainCheck.accepts(offsetMilliseconds: 0, intervals: plausible + [-3, -4, -5]))
        XCTAssertFalse(ClockDomainCheck.accepts(offsetMilliseconds: 0, intervals: []))

        var metrics = CaptureSessionMetrics(windowID: 42)
        metrics.presentClockOffsetMilliseconds = 12
        metrics.recordPresented(callbackToPresent: 20, frameAge: 21)
        XCTAssertTrue(metrics.summary(durationSeconds: 1, stopReason: "closed")
            .contains("callbackToPresent=[unchecked-clock]"))
    }

    func testSummaryCarriesCountsAndReasonOnly() {
        var metrics = CaptureSessionMetrics(windowID: 42)
        metrics.startMilliseconds = 120
        metrics.firstFrameMilliseconds = 95
        metrics.width = 1053
        metrics.height = 790
        metrics.pixelFormat = fourCharacterCode(0x42475241)
        metrics.recordStatus("complete")
        metrics.recordStatus("complete")
        metrics.recordStatus("idle")
        metrics.recordCaptureToCallback(1)
        metrics.recordPresented(callbackToPresent: 30, frameAge: 31)
        let line = metrics.summary(durationSeconds: 2, stopReason: "failed.targetQuit")
        XCTAssertTrue(line.contains("output=1053x790/BGRA"))
        XCTAssertTrue(line.contains("status=[complete=2,idle=1]"))
        XCTAssertTrue(line.contains("completeRate=1.0/s"))
        XCTAssertTrue(line.contains("frameAge=[n=1 p50=31.0"))
        XCTAssertTrue(line.hasSuffix("stop=failed.targetQuit"))
    }

    func testMissingDisplayTimestampDoesNotBecomeFrameAge() {
        var metrics = CaptureSessionMetrics(windowID: 42)
        metrics.recordPresented(callbackToPresent: 30, frameAge: nil)
        let line = metrics.summary(durationSeconds: 1, stopReason: "closed")
        XCTAssertTrue(line.contains("presented=1"))
        XCTAssertTrue(line.contains("callbackToPresent=[n=1"))
        XCTAssertTrue(line.contains("frameAge=[none]"))
    }
}
