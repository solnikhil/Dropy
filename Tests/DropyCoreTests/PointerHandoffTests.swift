import XCTest
import CoreGraphics
import Foundation
import DropyCore

final class PointerHandoffTests: XCTestCase {
    // The cast in the overlay, and the window on the Stage, at the same size.
    private let cast = CGRect(x: 527, y: 38, width: 656, height: 422)
    private let staged = CGRect(x: 1750, y: 1185, width: 656, height: 422)

    func testOutsideTheCastNothingHappens() {
        var handoff = PointerHandoff(cast: cast, staged: staged)
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 100, y: 100)), .none)
        XCTAssertFalse(handoff.onStage)
    }

    func testEnteringMovesThePointerToTheMatchingStagePoint() {
        var handoff = PointerHandoff(cast: cast, staged: staged)
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 600, y: 100)),
                       .enter(stage: CGPoint(x: 1823, y: 1247), cursor: CGPoint(x: 600, y: 100)))
        XCTAssertTrue(handoff.onStage)
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 1900, y: 1300)), .follow(cursor: CGPoint(x: 677, y: 153)))
    }

    func testLeavingReturnsJustOutsideTheSameEdge() {
        var handoff = PointerHandoff(cast: cast, staged: staged)
        _ = handoff.pointer(at: CGPoint(x: 600, y: 100))
        // Out through the left edge of the window on the Stage.
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 1749, y: 1300)), .leave(screen: CGPoint(x: 525, y: 153)))
        XCTAssertFalse(handoff.onStage)
        // The next move just outside does not re-enter.
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 525, y: 153)), .none)
    }

    func testLeavingThroughTheBottomAndRight() {
        var handoff = PointerHandoff(cast: cast, staged: staged)
        _ = handoff.pointer(at: CGPoint(x: 600, y: 100))
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 2000, y: 1607)), .leave(screen: CGPoint(x: 777, y: 462)))
        _ = handoff.pointer(at: CGPoint(x: 600, y: 100))
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 2406, y: 1300)), .leave(screen: CGPoint(x: 1185, y: 153)))
    }

    func testAScaledCastMapsBothWays() {
        let half = CGRect(x: 527, y: 38, width: 328, height: 211)
        var handoff = PointerHandoff(cast: half, staged: staged)
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 691, y: 143.5)),
                       .enter(stage: CGPoint(x: 2078, y: 1396), cursor: CGPoint(x: 691, y: 143.5)))
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 2078, y: 1396)), .follow(cursor: CGPoint(x: 691, y: 143.5)))
    }

    func testResetForgetsAPointerMovedElsewhere() {
        var handoff = PointerHandoff(cast: cast, staged: staged)
        _ = handoff.pointer(at: CGPoint(x: 600, y: 100))
        handoff.reset()
        XCTAssertFalse(handoff.onStage)
    }

    func testLiveCountsAsUsingTheRealWindow() {
        XCTAssertTrue(CapturePhase.live.isDocking)
        XCTAssertFalse(CapturePhase.live.isCapturing)
        XCTAssertEqual(CapturePhase.live.diagnosticName, "live")
    }

    func testOlderSettingsKeepPinnedAppsReady() throws {
        let saved = #"{"interaction":"fullApp"}"#.data(using: .utf8)!
        XCTAssertTrue(try JSONDecoder().decode(DropyPreferences.self, from: saved).keepsPinnedAppReady)
    }
}
