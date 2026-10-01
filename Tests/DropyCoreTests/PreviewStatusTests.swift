import Foundation
import XCTest
import DropyCore

final class PreviewStatusTests: XCTestCase {
    private let slowed = HiddenSourceRateMonitor.Assessment.slowedWhileHidden(before: 60, hidden: 5)
    private var note: String { HiddenSourceRateMonitor.label(slowed) ?? "" }

    private func line(_ phase: CapturePhase, hasWindows: Bool = true,
                      _ hiddenSource: HiddenSourceRateMonitor.Assessment = .notHidden) -> String {
        PreviewStatus.line(phase: phase, hasWindows: hasWindows, hiddenSource: hiddenSource)
    }

    func testTheSlowedNoteReplacesTheLivePreviewWording() {
        XCTAssertEqual(line(.viewing), CapturePhase.viewing.message)
        XCTAssertEqual(line(.viewing, slowed), note)
        XCTAssertEqual(note, "Hidden updates: 5 fps (was 60)")
    }

    func testTheNoteIsClearedWhenTheRateIsNotSlowed() {
        for assessment in [HiddenSourceRateMonitor.Assessment.notHidden, .unknown, .normal] {
            XCTAssertEqual(line(.viewing, assessment), CapturePhase.viewing.message,
                           "\(assessment.diagnosticName) must say nothing about the rate")
        }
    }

    func testAPausedStartingOrFailedPreviewNeverCarriesARateClaim() {
        // Frames have stopped or never started: a rate measured before that is stale,
        // and the phase's own reason is what the person needs.
        let paused = CapturePhase.paused(applicationName: "Safari")
        XCTAssertEqual(line(paused, slowed), paused.message)
        let starting = CapturePhase.starting(applicationName: "Safari")
        XCTAssertEqual(line(starting, slowed), starting.message)
        let failed = CapturePhase.failed(.permissionDenied)
        XCTAssertEqual(line(failed, slowed), failed.message)
        XCTAssertEqual(line(.closed, slowed), "")
        XCTAssertEqual(line(.selecting, slowed), PreviewStatus.choose)
    }

    func testThePickerLineSaysWhetherAnyWindowWasFound() {
        XCTAssertEqual(line(.selecting), PreviewStatus.choose)
        XCTAssertEqual(line(.selecting, hasWindows: false), PreviewStatus.noWindows)
        XCTAssertNotEqual(PreviewStatus.choose, PreviewStatus.noWindows)
    }

    func testTheAssessmentHasALogSafeName() {
        XCTAssertEqual(slowed.diagnosticName, "slowed(before=60,hidden=5)")
        XCTAssertEqual(HiddenSourceRateMonitor.Assessment.notHidden.diagnosticName, "notHidden")
        XCTAssertEqual(HiddenSourceRateMonitor.Assessment.unknown.diagnosticName, "unknown")
        XCTAssertEqual(HiddenSourceRateMonitor.Assessment.normal.diagnosticName, "normal")
    }
}
