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

    func testExpandedAspectFitMapsNewEdgesAndPreservesHandoff() {
        var handoff = PointerHandoff(cast: cast, staged: staged)
        _ = handoff.pointer(at: CGPoint(x: cast.midX, y: cast.midY))
        let viewport = CGRect(x: 24, y: 38, width: 1662, height: 911)
        handoff.updateLayout(viewport: viewport, stagedWindow: staged, mode: .fit)
        XCTAssertTrue(handoff.onStage)
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: staged.midX, y: staged.midY)),
                       .follow(cursor: CGPoint(x: viewport.midX, y: viewport.midY)))
        handoff.reset()
        let point = CGPoint(x: handoff.cast.maxX - 1, y: handoff.cast.midY)
        guard case .enter(let stagePoint, let cursor) = handoff.pointer(at: point) else {
            return XCTFail("The expanded part of the app must accept input")
        }
        XCTAssertTrue(staged.contains(stagePoint))
        XCTAssertEqual(cursor, point)
        handoff.reset()
        // Letterboxing belongs to Dropy, not to the app's input rectangle.
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: viewport.minX, y: viewport.midY)), .none)
    }

    func testFillAndNativeScaleMapOnlyTheVisibleSourceCrop() {
        let window = CGRect(x: 2000, y: 1000, width: 400, height: 200)
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 300)
        var handoff = PointerHandoff(cast: viewport, staged: window)
        handoff.updateLayout(viewport: viewport, stagedWindow: window, mode: .fill)
        XCTAssertEqual(handoff.cast, viewport)
        XCTAssertEqual(handoff.staged, CGRect(x: 2100, y: 1000, width: 200, height: 200))
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 75, y: 150)),
                       .enter(stage: CGPoint(x: 2150, y: 1100), cursor: CGPoint(x: 75, y: 150)))
        handoff.reset()
        handoff.updateLayout(viewport: viewport, stagedWindow: window, mode: .nativeScale)
        XCTAssertEqual(handoff.cast, CGRect(x: 0, y: 50, width: 300, height: 200))
        XCTAssertEqual(handoff.staged, CGRect(x: 2050, y: 1000, width: 300, height: 200))
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 75, y: 150)),
                       .enter(stage: CGPoint(x: 2125, y: 1100), cursor: CGPoint(x: 75, y: 150)))
        handoff.reset()
        handoff.updateLayout(viewport: viewport, stagedWindow: window, mode: .fit)
        XCTAssertEqual(handoff.staged, window, "Returning to Fit must undo cropping")
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
