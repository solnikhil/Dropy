import XCTest
import CoreGraphics
import Foundation
import DropyCore

final class PointerHandoffTests: XCTestCase {
    // The overlay's display, the Stage past its corner, and the app's window as the
    // person sees it in the overlay; on the Stage it is at the same spot, one to one.
    private let display = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    private let stage = CGRect(x: 1710, y: 1112, width: 1710, height: 1112)
    private let cast = CGRect(x: 527, y: 38, width: 656, height: 422)
    private var offset: CGVector { CGVector(dx: stage.minX - display.minX, dy: stage.minY - display.minY) }

    func testOutsideTheAppNothingHappens() {
        var handoff = PointerHandoff(offset: offset, regions: [cast])
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 100, y: 100)), .none)
        XCTAssertFalse(handoff.onStage)
    }

    func testEnteringMovesThePointerToTheSameSpotOnTheStage() {
        var handoff = PointerHandoff(offset: offset, regions: [cast])
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 600, y: 100)),
                       .enter(stage: CGPoint(x: 2310, y: 1212), cursor: CGPoint(x: 600, y: 100)))
        XCTAssertTrue(handoff.onStage)
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 2400, y: 1300)), .follow(cursor: CGPoint(x: 690, y: 188)))
    }

    func testLeavingReturnsToTheExactPointWithoutAJump() {
        var handoff = PointerHandoff(offset: offset, regions: [cast])
        _ = handoff.pointer(at: CGPoint(x: 600, y: 100))
        // One point past the window's left edge on the Stage is one point past the cast's.
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 2236, y: 1300)), .leave(screen: CGPoint(x: 526, y: 188)))
        XCTAssertFalse(handoff.onStage)
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 526, y: 188)), .none)
        // And straight back in.
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 527, y: 188)),
                       .enter(stage: CGPoint(x: 2237, y: 1300), cursor: CGPoint(x: 527, y: 188)))
    }

    func testAMenuOutsideTheOverlayKeepsThePointerOnTheStage() {
        // A context menu opened near the window's bottom edge reaches past the overlay.
        let menu = CGRect(x: 900, y: 400, width: 220, height: 300)
        var handoff = PointerHandoff(offset: offset, regions: [cast, menu])
        _ = handoff.pointer(at: CGPoint(x: 950, y: 420))
        let belowTheOverlay = handoff.stagePoint(CGPoint(x: 950, y: 650))
        XCTAssertEqual(handoff.pointer(at: belowTheOverlay), .follow(cursor: CGPoint(x: 950, y: 650)))
        // The menu reached from outside, too.
        handoff.reset()
        XCTAssertEqual(handoff.pointer(at: CGPoint(x: 1000, y: 690)),
                       .enter(stage: CGPoint(x: 2710, y: 1802), cursor: CGPoint(x: 1000, y: 690)))
    }

    func testRegionsComeFromTheAppsWindowsOnTheStage() {
        let window = cast
        let own: Int32 = 99
        let rows: [PointerHandoff.StageWindow] = [
            // The window itself, a popover, a context menu, a sheet's shadow edge past the Stage.
            .init(bounds: window.offsetBy(dx: offset.dx, dy: offset.dy), layer: 0, processID: 7),
            .init(bounds: CGRect(x: 2400, y: 1500, width: 300, height: 200), layer: 3, processID: 7),
            .init(bounds: CGRect(x: 2610, y: 1500, width: 200, height: 260), layer: 101, processID: 7),
            .init(bounds: CGRect(x: 3300, y: 2100, width: 400, height: 400), layer: 8, processID: 30),
            // Not the app's: the Stage's menu bar and status items, its desktop, Dropy's curtain.
            .init(bounds: CGRect(x: 1710, y: 1112, width: 1710, height: 24), layer: 24, processID: 40),
            .init(bounds: CGRect(x: 3300, y: 1112, width: 30, height: 24), layer: 25, processID: 41),
            .init(bounds: stage, layer: -2147483623, processID: 42),
            .init(bounds: stage, layer: 0, processID: own),
            // Another app's window waiting on the Stage to go home to its desktop.
            .init(bounds: CGRect(x: 1800, y: 1700, width: 500, height: 400), layer: 0, processID: 50),
            // On a real display, not the Stage.
            .init(bounds: CGRect(x: 10, y: 10, width: 300, height: 300), layer: 0, processID: 7),
        ]
        let regions = PointerHandoff.regions(of: rows, window: window, stage: stage, offset: offset,
                                             appProcess: 7, ownProcess: own)
        XCTAssertEqual(regions, [
            window,
            CGRect(x: 690, y: 388, width: 300, height: 200),
            CGRect(x: 900, y: 388, width: 200, height: 260),
            CGRect(x: 1590, y: 988, width: 120, height: 124),
        ])
    }

    func testTheStageMirrorsTheDisplayBelowItsMenuBar() {
        XCTAssertEqual(StageGeometry.mirrored(cast, display: display, stage: stage, menuBarHeight: 24),
                       cast.offsetBy(dx: 1710, dy: 1112))
        // Up under the Stage's menu bar, the window waits just below it.
        let high = CGRect(x: 527, y: 10, width: 656, height: 422)
        XCTAssertEqual(StageGeometry.mirrored(high, display: display, stage: stage, menuBarHeight: 24),
                       CGRect(x: 2237, y: 1136, width: 656, height: 422))
        // A display that is not at the origin.
        let external = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(StageGeometry.mirrored(CGRect(x: -1500, y: -150, width: 800, height: 600), display: external,
                                              stage: stage, menuBarHeight: 24),
                       CGRect(x: 2130, y: 1162, width: 800, height: 600))
    }

    func testResetForgetsAPointerMovedElsewhere() {
        var handoff = PointerHandoff(offset: offset, regions: [cast])
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
