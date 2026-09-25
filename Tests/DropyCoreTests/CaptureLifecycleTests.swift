import Foundation
import XCTest
import DropyCore

final class CaptureLifecycleTests: XCTestCase {
    private let domain = CaptureErrorKind.streamErrorDomain

    func testStreamErrorsMapToDistinctRecoveries() {
        XCTAssertEqual(CaptureErrorKind.classify(domain: domain, code: -3801), .permissionDenied)
        XCTAssertEqual(CaptureErrorKind.classify(domain: domain, code: -3817), .stoppedFromSystemControls)
        XCTAssertEqual(CaptureErrorKind.classify(domain: domain, code: -3815), .sourceMissing)
        XCTAssertEqual(CaptureErrorKind.classify(domain: domain, code: -3805), .sourceMissing)
        XCTAssertEqual(CaptureErrorKind.classify(domain: domain, code: -3821), .interrupted)
        XCTAssertEqual(CaptureErrorKind.classify(domain: NSCocoaErrorDomain, code: -3801), .interrupted)
    }

    func testFailuresAreDistinctAndOnlyPermissionOpensSettings() {
        let failures: [CaptureFailure] = [
            .permissionDenied, .sourceWindowClosed(applicationName: "TextEdit"),
            .targetQuit(applicationName: "TextEdit"), .stoppedFromSystemControls,
            .streamInterrupted(code: -3821), .windowListUnavailable(code: -3813),
        ]
        XCTAssertEqual(Set(failures.map(\.message)).count, failures.count)
        XCTAssertEqual(failures.filter(\.opensPrivacySettings), [.permissionDenied])
    }

    func testOnlyActiveCapturePhasesOwnAStream() {
        XCTAssertTrue(CapturePhase.starting(applicationName: "Safari").isCapturing)
        XCTAssertTrue(CapturePhase.viewing.isCapturing)
        XCTAssertTrue(CapturePhase.paused(applicationName: "Safari").isCapturing)
        XCTAssertFalse(CapturePhase.selecting.isCapturing)
        XCTAssertFalse(CapturePhase.closed.isCapturing)
        XCTAssertFalse(CapturePhase.failed(.permissionDenied).isCapturing)
        XCTAssertEqual(CapturePhase.failed(.stoppedFromSystemControls).failure, .stoppedFromSystemControls)
        XCTAssertNil(CapturePhase.viewing.failure)
    }
}
