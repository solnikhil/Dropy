import XCTest
import Foundation
import DropyCore

final class SessionModePolicyTests: XCTestCase {
    private func mode(_ interaction: InteractionMode = .fullApp, trusted: Bool = true, fullScreen: Bool = false,
                      stage: Bool = false) -> SessionMode {
        SessionModePolicy.mode(for: SessionConditions(interaction: interaction, accessibilityTrusted: trusted,
                                                      fullScreenInFront: fullScreen, stageAvailable: stage))
    }

    func testFullAppDocksTheRealWindow() {
        XCTAssertEqual(mode(), .native)
        XCTAssertEqual(mode(stage: true), .native, "the Stage changes where a window waits, not how it is used")
    }

    func testPreviewOnlyAndMissingAccessibilityPreview() {
        XCTAssertEqual(mode(.previewOnly), .preview)
        XCTAssertEqual(mode(.previewOnly, fullScreen: true, stage: true), .preview)
        XCTAssertEqual(mode(trusted: false), .preview)
        XCTAssertEqual(mode(trusted: false, fullScreen: true, stage: true), .preview)
    }

    func testFullScreenNeedsTheStage() {
        XCTAssertEqual(mode(fullScreen: true, stage: true), .live)
        XCTAssertEqual(mode(fullScreen: true, stage: false), .preview)
    }

    func testNotesExplainOnlyAnUnwantedPreview() {
        func note(_ interaction: InteractionMode = .fullApp, trusted: Bool = true, fullScreen: Bool = false) -> String? {
            SessionModePolicy.previewNote(for: SessionConditions(interaction: interaction, accessibilityTrusted: trusted,
                                                                 fullScreenInFront: fullScreen))
        }
        XCTAssertNil(note(), "a docked window needs no note")
        XCTAssertNil(note(.previewOnly), "the person chose Preview")
        XCTAssertEqual(note(trusted: false), "View only · Allow Accessibility for Dropy in Settings to use apps here")
        XCTAssertEqual(note(fullScreen: true), "View only · An app can't be brought over a full-screen app yet")
    }

    func testCaptureErrorsMapToFailures() {
        let domain = CaptureErrorKind.streamErrorDomain
        XCTAssertEqual(CaptureFailure.stream(domain: domain, code: -3801), .permissionDenied)
        XCTAssertEqual(CaptureFailure.stream(domain: domain, code: -3817), .stoppedFromSystemControls)
        XCTAssertEqual(CaptureFailure.stream(domain: domain, code: -3813), .windowListUnavailable(code: -3813))
        XCTAssertEqual(CaptureFailure.stream(domain: domain, code: -3815), .streamInterrupted(code: -3815))
        XCTAssertEqual(CaptureFailure.stream(domain: "other", code: 7), .streamInterrupted(code: 7))
        XCTAssertEqual(CaptureFailure.catalog(domain: domain, code: -3801), .permissionDenied)
        XCTAssertEqual(CaptureFailure.catalog(domain: domain, code: -3815), .windowListUnavailable(code: -3815))
    }
}
