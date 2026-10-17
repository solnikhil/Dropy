import XCTest
import DropyCore

final class LiveLayoutReadinessTests: XCTestCase {
    func testImmediateLayoutResumeStillWaitsForSourcePlacement() {
        var readiness = LiveLayoutReadiness()
        let move = UUID()
        readiness.beginMove(move)
        readiness.suspendAnimation()
        readiness.resumeAnimation()
        XCTAssertFalse(readiness.allowsInput)
        readiness.finishMove(move)
        XCTAssertTrue(readiness.allowsInput, "A nonanimated resize must not stay blocked by dismissal grace timing")
    }

    func testSourcePlacementStillWaitsForAnimation() {
        var readiness = LiveLayoutReadiness()
        let move = UUID()
        readiness.suspendAnimation()
        readiness.beginMove(move)
        readiness.finishMove(move)
        XCTAssertFalse(readiness.allowsInput)
        readiness.resumeAnimation()
        XCTAssertTrue(readiness.allowsInput)
    }

    func testStaleCompletionCannotUnlockNewerGeometry() {
        var readiness = LiveLayoutReadiness()
        let old = UUID(), newest = UUID()
        readiness.beginMove(old)
        readiness.beginMove(newest)
        XCTAssertTrue(readiness.isMoving)
        readiness.finishMove(old)
        XCTAssertFalse(readiness.allowsInput)
        readiness.finishMove(newest)
        XCTAssertFalse(readiness.isMoving)
        XCTAssertTrue(readiness.allowsInput)
        readiness.suspendAnimation()
        readiness.beginMove(newest)
        readiness.reset()
        XCTAssertTrue(readiness.allowsInput)
    }
}
