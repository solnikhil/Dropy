import Foundation
import XCTest
import DropyCore

final class HiddenSourceRateMonitorTests: XCTestCase {
    /// Changed frames at `fps` from `start` (inclusive) to `end` (exclusive).
    private func feed(_ monitor: inout HiddenSourceRateMonitor, fps: Double, from start: Double, to end: Double) {
        guard fps > 0 else { return }
        // By index, not by accumulating 1/fps, which drifts and drops frames.
        let count = Int(((end - start) * fps).rounded())
        for index in 0..<count { monitor.recordChangedFrame(at: start + Double(index) / fps) }
    }

    func testSafariLikeDropIsReportedAfterAFullWindow() {
        // Measured: an animating Safari page fell from about 60 to about 5 fps once parked.
        var monitor = HiddenSourceRateMonitor()
        feed(&monitor, fps: 60, from: 0, to: 10)
        monitor.sourceHidden(at: 10)
        feed(&monitor, fps: 5, from: 10, to: 11)
        XCTAssertEqual(monitor.assessment(at: 11), .unknown, "one second is less than a measuring window")
        feed(&monitor, fps: 5, from: 11, to: 12)
        guard case .slowedWhileHidden(let before, let hidden) = monitor.assessment(at: 12) else {
            return XCTFail("not reported: \(monitor.assessment(at: 12))")
        }
        XCTAssertEqual(before, 60, accuracy: 1)
        XCTAssertEqual(hidden, 5, accuracy: 1)
        XCTAssertEqual(HiddenSourceRateMonitor.label(monitor.assessment(at: 12)),
                       "Hidden updates: 5 fps (was 60)")
    }

    func testAKeptRateIsNormal() {
        var monitor = HiddenSourceRateMonitor()
        feed(&monitor, fps: 60, from: 0, to: 5)
        monitor.sourceHidden(at: 5)
        feed(&monitor, fps: 55, from: 5, to: 8)
        XCTAssertEqual(monitor.assessment(at: 8), .normal)
        XCTAssertNil(HiddenSourceRateMonitor.label(.normal))
    }

    func testAStaticSourceIsNeverCalledSlowed() {
        // A document that is not changing delivers almost no frames, hidden or not.
        var monitor = HiddenSourceRateMonitor()
        feed(&monitor, fps: 2, from: 0, to: 5)
        monitor.sourceHidden(at: 5)
        XCTAssertEqual(monitor.assessment(at: 9), .unknown)
        // Nothing at all before hiding.
        var silent = HiddenSourceRateMonitor()
        silent.sourceHidden(at: 5)
        XCTAssertEqual(silent.assessment(at: 9), .unknown)
    }

    func testACaptureYoungerThanAWindowHasNoBaseline() {
        var monitor = HiddenSourceRateMonitor()
        feed(&monitor, fps: 60, from: 4, to: 5)
        monitor.sourceHidden(at: 5)
        XCTAssertEqual(monitor.assessment(at: 8), .unknown)
    }

    func testShowingTheWindowClearsTheAssessment() {
        var monitor = HiddenSourceRateMonitor()
        feed(&monitor, fps: 60, from: 0, to: 5)
        monitor.sourceHidden(at: 5)
        XCTAssertEqual(monitor.assessment(at: 8), .slowedWhileHidden(before: 60, hidden: 0))
        monitor.sourceShown()
        XCTAssertEqual(monitor.assessment(at: 8), .notHidden)
        // Hidden again later: the baseline is measured afresh from the frames before.
        feed(&monitor, fps: 30, from: 8, to: 12)
        monitor.sourceHidden(at: 12)
        feed(&monitor, fps: 30, from: 12, to: 15)
        XCTAssertEqual(monitor.assessment(at: 15), .normal)
    }

    func testRepeatedHideDoesNotMoveTheBaselineAndOutOfOrderFramesAreIgnored() {
        var monitor = HiddenSourceRateMonitor()
        feed(&monitor, fps: 60, from: 0, to: 5)
        monitor.sourceHidden(at: 5)
        monitor.sourceHidden(at: 7)  // no-op: already hidden
        monitor.recordChangedFrame(at: 3)  // earlier than the last frame
        monitor.recordChangedFrame(at: .nan)
        XCTAssertEqual(monitor.assessment(at: 7), .slowedWhileHidden(before: 60, hidden: 0))
    }

    func testALongCaptureHoldsOnlyTheTwoWindowsAndStillMeasuresCorrectly() {
        // A preview left running for an hour must not accumulate an hour of frame times,
        // and dropping them must not cost a shift of the whole buffer per frame: frames
        // are dropped by moving an index and the array is compacted once half of it is
        // dead. That leaves at most twice what the windows need: 2 x window x 60 fps
        // live frames, and fewer dead ones than live, so under 500 for these rates.
        var monitor = HiddenSourceRateMonitor()
        feed(&monitor, fps: 60, from: 0, to: 60)
        XCTAssertTrue(monitor.heldFrameCount < 500,
                      "3600 frames fed, \(monitor.heldFrameCount) held")
        // And the measurement is unaffected by how often the buffer was compacted. The
        // frames run from just after the hiding to the verdict: the window is half-open,
        // so ten frames at 5 fps land in it.
        monitor.sourceHidden(at: 60)
        feed(&monitor, fps: 5, from: 60.2, to: 62.2)
        XCTAssertEqual(monitor.assessment(at: 62), .slowedWhileHidden(before: 60, hidden: 5))
        XCTAssertTrue(monitor.heldFrameCount < 500, "\(monitor.heldFrameCount) held while hidden")
    }

    func testOnlyReadingsFromOneClockAgree() {
        // Two reads of one clock, a little work apart.
        XCTAssertTrue(HiddenSourceRateMonitor.clocksAgree(41_233.100, 41_233.104))
        XCTAssertTrue(HiddenSourceRateMonitor.clocksAgree(41_233.100, 41_233.100))
        // Seconds since boot against seconds since 1970: the mistake this rules out.
        XCTAssertFalse(HiddenSourceRateMonitor.clocksAgree(41_233.100, 1_790_000_000))
        // A gap too long to be two reads in succession, either way round.
        XCTAssertFalse(HiddenSourceRateMonitor.clocksAgree(41_233.100, 41_233.400))
        XCTAssertFalse(HiddenSourceRateMonitor.clocksAgree(41_233.400, 41_233.100))
        // A wider tolerance admits a longer gap; the default does not.
        XCTAssertTrue(HiddenSourceRateMonitor.clocksAgree(10, 10.04))
        XCTAssertFalse(HiddenSourceRateMonitor.clocksAgree(10, 10.06))
        XCTAssertTrue(HiddenSourceRateMonitor.clocksAgree(10, 10.4, tolerance: 0.5))
        // A clock that produced no reading agrees with nothing, including itself: the
        // difference is NaN and every comparison against it is false.
        XCTAssertFalse(HiddenSourceRateMonitor.clocksAgree(.nan, 10))
        XCTAssertFalse(HiddenSourceRateMonitor.clocksAgree(.nan, .nan))
        XCTAssertFalse(HiddenSourceRateMonitor.clocksAgree(.infinity, .infinity))
        XCTAssertFalse(HiddenSourceRateMonitor.clocksAgree(.nan, .nan, tolerance: .infinity))
    }
}
