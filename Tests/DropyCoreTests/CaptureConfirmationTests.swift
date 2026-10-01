import XCTest
import DropyCore

final class CaptureConfirmationTests: XCTestCase {
    func testPendingStopHasItsOwnRecoveryMessage() {
        XCTAssertFalse(CaptureFailure.previousStreamStopping.opensPrivacySettings)
        XCTAssertTrue(CaptureFailure.previousStreamStopping.message.contains("still stopping"))
    }

    func testStaleAndUnpresentedContentIsRefused() {
        let lease = CaptureConfirmation()
        XCTAssertFalse(lease.permits(revision: nil, at: 0))
        let first = lease.observe(changed: true, at: 10)
        XCTAssertTrue(lease.permits(revision: first, at: 510))
        XCTAssertFalse(lease.permits(revision: first, at: 511))
        let second = lease.observe(changed: true, at: 520)
        XCTAssertFalse(lease.permits(revision: first, at: 521))
        XCTAssertTrue(lease.permits(revision: second, at: 521))
        XCTAssertFalse(lease.permits(revision: second, at: 519))
    }

    func testStaticCallbacksRefreshWithoutInventingAPresentedFrame() {
        let lease = CaptureConfirmation()
        XCTAssertNil(lease.observe(changed: false, at: 0))
        let first = lease.observe(changed: true, at: 10)
        XCTAssertEqual(lease.observe(changed: false, at: 900), first)
        XCTAssertTrue(lease.permits(revision: first, at: 901))
        lease.invalidate()
        XCTAssertNil(lease.observe(changed: true, at: 902))
        XCTAssertFalse(lease.permits(revision: first, at: 903))
    }
}
