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
                       "Hidden source slowed by its app · about 5 fps (was 60)")
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
}
