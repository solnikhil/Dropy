import XCTest
import CoreGraphics
import Foundation
import DropyCore

final class StageGeometryTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1710, height: 1112)

    func testStageMatchesTheNotchDisplayInEvenPoints() {
        XCTAssertEqual(StageGeometry.size(for: CGSize(width: 1710, height: 1112)), CGSize(width: 1710, height: 1112))
        XCTAssertEqual(StageGeometry.size(for: CGSize(width: 1511, height: 981)), CGSize(width: 1510, height: 980))
    }

    func testStageTouchesTheDisplaysAtOneCorner() {
        // Measured on 2026-10-07: macOS keeps a display placed at this corner.
        XCTAssertEqual(StageGeometry.origin(displays: [main]), CGPoint(x: 1710, y: 1112))
        let external = CGRect(x: 1710, y: -200, width: 2560, height: 1440)
        XCTAssertEqual(StageGeometry.origin(displays: [main, external]), CGPoint(x: 4270, y: 1240))
        XCTAssertEqual(StageGeometry.origin(displays: []), .zero)
    }

    func testWindowsWaitBelowTheStageMenuBarInsideTheMargin() {
        let stage = CGRect(x: 1710, y: 1112, width: 1710, height: 1112)
        XCTAssertEqual(StageGeometry.slot(for: CGSize(width: 900, height: 600), stage: stage, menuBarHeight: 33),
                       CGPoint(x: 1750, y: 1185))
    }

    func testPointerMapsBetweenTheOverlayAndTheStage() {
        let overlay = CGRect(x: 527, y: 38, width: 656, height: 422)
        let staged = CGRect(x: 1750, y: 1185, width: 656, height: 422)
        XCTAssertEqual(StageGeometry.map(CGPoint(x: 527, y: 38), from: overlay, to: staged), CGPoint(x: 1750, y: 1185))
        XCTAssertEqual(StageGeometry.map(CGPoint(x: 855, y: 249), from: overlay, to: staged), CGPoint(x: 2078, y: 1396))
        // A scaled cast maps proportionally.
        let half = CGRect(x: 0, y: 0, width: 328, height: 211)
        XCTAssertEqual(StageGeometry.map(CGPoint(x: 164, y: 105.5), from: half, to: staged), CGPoint(x: 2078, y: 1396))
    }

    func testAWanderingPointerGoesBackToTheNearestDisplay() {
        XCTAssertEqual(StageGeometry.nearestPoint(to: CGPoint(x: 1800, y: 1200), on: [main]), CGPoint(x: 1709, y: 1111))
        XCTAssertEqual(StageGeometry.nearestPoint(to: CGPoint(x: 500, y: 300), on: [main]), CGPoint(x: 500, y: 300))
    }

    func testStagedWindowsRestoreTheirSize() {
        XCTAssertTrue(PlacementMode.staged.movesWindow)
        XCTAssertTrue(PlacementMode.staged.resizesWindow)
        XCTAssertFalse(PlacementMode.parked.resizesWindow)
    }
}
