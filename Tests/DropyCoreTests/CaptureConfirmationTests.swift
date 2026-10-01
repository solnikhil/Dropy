import XCTest
import DropyCore

final class CaptureConfirmationTests: XCTestCase {
    func testRestorationRequiresObservedState() {
        let expected = WindowPlacementState(frame: CGRect(x: 20, y: 20, width: 400, height: 300),
                                            isMinimized: false, isAppHidden: false)
        let decision = RestoreDecision.restore(expected)
        XCTAssertEqual(RestoreConfirmation.check(decision, read: .state(expected)), .success(decision))
        var hidden = expected
        hidden.frame.origin.x = -1000
        XCTAssertEqual(RestoreConfirmation.check(decision, read: .state(hidden)),
                       .failure(.applyFailed("restorationNotObserved")))
        XCTAssertEqual(RestoreConfirmation.check(decision, read: .failed("busy")), .failure(.readFailed("busy")))
        XCTAssertEqual(RestoreConfirmation.check(decision, read: .unreachable(.onOtherSpace)),
                       .failure(.windowUnreachable(.onOtherSpace)))
    }

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
