import XCTest
import CoreGraphics
import Foundation
import DropyCore

final class OverlayPositionTests: XCTestCase {
    // A 14-inch MacBook Pro: 1512 × 982 points, a 33 pt menu bar and a 70 pt Dock.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 70, width: 1512, height: 879)
    private let size = CGSize(width: 600, height: 360)

    // MARK: Placement

    func testEachPositionIsFlushWithItsEdges() {
        let notch = OverlayPosition.notch.body(size: size, screen: screen, visible: visible)
        XCTAssertEqual(notch.maxY, screen.maxY)
        XCTAssertEqual(notch.midX, screen.midX)

        let left = OverlayPosition.left.body(size: size, screen: screen, visible: visible)
        XCTAssertEqual(left.minX, screen.minX)
        XCTAssertEqual(left.midY, visible.midY, "centered between the menu bar and the Dock")

        let right = OverlayPosition.right.body(size: size, screen: screen, visible: visible)
        XCTAssertEqual(right.maxX, screen.maxX)
        XCTAssertEqual(right.midY, visible.midY)

        let bottomLeft = OverlayPosition.bottomLeft.body(size: size, screen: screen, visible: visible)
        XCTAssertEqual(bottomLeft.origin, CGPoint(x: 0, y: visible.minY), "on top of the Dock, never under it")

        let bottomRight = OverlayPosition.bottomRight.body(size: size, screen: screen, visible: visible)
        XCTAssertEqual(bottomRight.maxX, screen.maxX)
        XCTAssertEqual(bottomRight.minY, visible.minY)

        for position in OverlayPosition.allCases {
            XCTAssertEqual(position.body(size: size, screen: screen, visible: visible).size, size)
        }
    }

    func testTheDockMovesTheEdgeItSitsOn() {
        // A hidden Dock leaves a few points: the real screen edge is kept.
        let hidden = CGRect(x: 0, y: 4, width: 1512, height: 945)
        XCTAssertEqual(OverlayPosition.bottomLeft.body(size: size, screen: screen, visible: hidden).origin, .zero)
        // A Dock on the left: the left edge and the left corner move beside it, the
        // right side and the notch do not.
        let leftDock = CGRect(x: 64, y: 0, width: 1448, height: 949)
        XCTAssertEqual(OverlayPosition.left.body(size: size, screen: screen, visible: leftDock).minX, 64)
        XCTAssertEqual(OverlayPosition.bottomLeft.body(size: size, screen: screen, visible: leftDock).origin,
                       CGPoint(x: 64, y: 0))
        XCTAssertEqual(OverlayPosition.right.body(size: size, screen: screen, visible: leftDock).maxX, screen.maxX)
        XCTAssertEqual(OverlayPosition.notch.body(size: size, screen: screen, visible: leftDock).midX, screen.midX)
        // The window's room above a bottom Dock reaches the top of the screen.
        XCTAssertEqual(OverlayPosition.edges(screen: screen, visible: visible),
                       CGRect(x: 0, y: 70, width: 1512, height: 912))
        // Nothing of the canvas reaches under the Dock.
        let body = OverlayPosition.bottomRight.body(size: size, screen: screen, visible: visible)
        XCTAssertEqual(OverlayPosition.bottomRight.canvas(around: body, margin: 30, screen: screen, visible: visible).minY,
                       visible.minY)
    }

    func testATallBodyAtASideEdgeStaysBelowTheMenuBar() {
        let tall = CGSize(width: 600, height: 920)
        let body = OverlayPosition.left.body(size: tall, screen: screen, visible: visible)
        XCTAssertEqual(body.maxY, visible.maxY)
        XCTAssertTrue(body.minY >= screen.minY)
    }

    func testPlacementWorksOnASecondDisplay() {
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        let body = OverlayPosition.bottomRight.body(size: size, screen: external, visible: external)
        XCTAssertEqual(body.maxX, external.maxX)
        XCTAssertEqual(body.minY, external.minY)
    }

    func testTheCanvasLeavesNoMarginPastTheScreenEdges() {
        for position in OverlayPosition.allCases {
            let body = position.body(size: size, screen: screen, visible: visible)
            let canvas = position.canvas(around: body, margin: 30, screen: screen)
            XCTAssertTrue(screen.contains(canvas), "\(position)")
            XCTAssertTrue(canvas.contains(body), "\(position)")
        }
        let left = OverlayPosition.left.body(size: size, screen: screen, visible: visible)
        let canvas = OverlayPosition.left.canvas(around: left, margin: 30, screen: screen)
        XCTAssertEqual(canvas.minX, left.minX)
        XCTAssertEqual(canvas.maxX, left.maxX + 30)
        XCTAssertEqual(canvas.height, left.height + 60)
    }

    func testBodiesAroundAWindowReachTheirEdges() {
        let around = CGRect(x: 40, y: 100, width: 500, height: 300)
        XCTAssertEqual(OverlayPosition.notch.reachingEdges(around, screen: screen).maxY, screen.maxY)
        XCTAssertEqual(OverlayPosition.left.reachingEdges(around, screen: screen),
                       CGRect(x: 0, y: 100, width: 540, height: 300))
        XCTAssertEqual(OverlayPosition.bottomRight.reachingEdges(around, screen: screen),
                       CGRect(x: 40, y: 0, width: 1472, height: 400))
    }

    // MARK: Outline

    func testTheNotchOutlineIsUnchanged() {
        let body = CGRect(x: 100, y: 50, width: 400, height: 300)
        let shape = NotchShape.open(body: body)
        XCTAssertEqual(shape.position, .notch)
        let bounds = shape.fillPath.boundingBoxOfPath
        XCTAssertEqual(bounds.minX, body.minX - NotchShape.openEarRadius, accuracy: 0.001)
        XCTAssertEqual(bounds.maxX, body.maxX + NotchShape.openEarRadius, accuracy: 0.001)
        XCTAssertEqual(bounds.maxY, body.maxY, accuracy: 0.001)
        XCTAssertEqual(bounds.minY, body.minY, accuracy: 0.001)
    }

    func testASideEdgeOutlineIsTheNotchOutlineTurned() {
        let ear = NotchShape.openEarRadius
        let body = CGRect(x: 0, y: 200, width: 400, height: 300)
        let left = NotchShape.open(body: body, at: .left).fillPath.boundingBoxOfPath
        XCTAssertEqual(left.minX, body.minX, accuracy: 0.001)
        XCTAssertEqual(left.maxX, body.maxX, accuracy: 0.001)
        XCTAssertEqual(left.minY, body.minY - ear, accuracy: 0.001, "ears reach along the edge")
        XCTAssertEqual(left.maxY, body.maxY + ear, accuracy: 0.001)

        let right = NotchShape.open(body: body.offsetBy(dx: 500, dy: 0), at: .right).fillPath.boundingBoxOfPath
        XCTAssertEqual(right.maxX, body.maxX + 500, accuracy: 0.001)
        XCTAssertEqual(right.minX, body.minX + 500, accuracy: 0.001)
        XCTAssertEqual(right.height, body.height + 2 * ear, accuracy: 0.001)

        // The rounded corners face into the screen: the edge side is straight.
        let path = NotchShape.open(body: body, at: .left).fillPath
        XCTAssertTrue(path.contains(CGPoint(x: body.minX + 0.5, y: body.minY + 0.5)))
        XCTAssertFalse(path.contains(CGPoint(x: body.maxX - 0.5, y: body.minY + 0.5)))
    }

    func testACornerOutlineFillsTheScreenCornerAndRoundsTheOppositeOne() {
        let ear = NotchShape.openEarRadius
        let body = CGRect(x: 0, y: 0, width: 400, height: 300)
        let shape = NotchShape.open(body: body, at: .bottomLeft)
        let bounds = shape.fillPath.boundingBoxOfPath
        XCTAssertEqual(bounds.minX, 0, accuracy: 0.001)
        XCTAssertEqual(bounds.minY, 0, accuracy: 0.001)
        XCTAssertEqual(bounds.maxX, body.maxX + ear, accuracy: 0.001)
        XCTAssertEqual(bounds.maxY, body.maxY + ear, accuracy: 0.001)
        let path = shape.fillPath
        XCTAssertTrue(path.contains(CGPoint(x: 0.5, y: 0.5)), "the screen's corner is filled")
        XCTAssertTrue(path.contains(CGPoint(x: body.maxX - 0.5, y: 0.5)))
        XCTAssertFalse(path.contains(CGPoint(x: body.maxX - 0.5, y: body.maxY - 0.5)), "the inner corner is rounded")
        // The hairline does not run along the screen edges.
        let stroke = shape.strokePath.boundingBoxOfPath
        XCTAssertEqual(stroke.minX, 0, accuracy: 0.001)
        XCTAssertEqual(stroke.minY, 0, accuracy: 0.001)

        let mirrored = NotchShape.open(body: body.offsetBy(dx: 1112, dy: 0), at: .bottomRight).fillPath
        XCTAssertTrue(mirrored.contains(CGPoint(x: 1511.5, y: 0.5)))
        XCTAssertFalse(mirrored.contains(CGPoint(x: 1112.5, y: body.maxY - 0.5)))
        XCTAssertEqual(mirrored.boundingBoxOfPath.minX, 1112 - ear, accuracy: 0.001)
    }

    func testOffsettingKeepsThePosition() {
        let shape = NotchShape.open(body: CGRect(x: 0, y: 0, width: 100, height: 100), at: .bottomRight)
        XCTAssertEqual(shape.offsetBy(dx: 3, dy: 4).position, .bottomRight)
    }

    // MARK: Morph

    func testOpeningFromASideEdgeStaysOnTheEdgeAndCentered() {
        let body = CGRect(x: 0, y: 300, width: 600, height: 360)
        let start = NotchShape.nub(for: body, at: .left)
        let end = NotchShape.open(body: body, at: .left)
        XCTAssertEqual(start.body.minX, 0)
        XCTAssertEqual(start.body.midY, body.midY)
        let frames = NotchMorph.frames(from: start, to: end, motion: NotchMorph.open)
        XCTAssertEqual(frames.shapes.last, end)
        for shape in frames.shapes {
            XCTAssertEqual(shape.position, .left)
            XCTAssertEqual(shape.body.minX, 0, accuracy: 0.001, "attached to the left edge")
            XCTAssertEqual(shape.body.midY, body.midY, accuracy: 0.001)
        }
        // Width is along the edge (the height on screen); height reaches into the screen.
        let part = NotchMorph.shape(from: start, to: end, widthProgress: 1, heightProgress: 0)
        XCTAssertEqual(part.body.height, body.height, accuracy: 0.001)
        XCTAssertEqual(part.body.width, start.body.width, accuracy: 0.001)
    }

    func testOpeningFromTheRightEdgeStaysOnTheRightEdge() {
        let body = CGRect(x: 912, y: 300, width: 600, height: 360)
        let frames = NotchMorph.frames(from: .nub(for: body, at: .right), to: .open(body: body, at: .right),
                                       motion: NotchMorph.open)
        for shape in frames.shapes { XCTAssertEqual(shape.body.maxX, body.maxX, accuracy: 0.001) }
    }

    func testOpeningFromACornerKeepsTheCornerFixed() {
        let body = CGRect(x: 912, y: 0, width: 600, height: 360)
        let start = NotchShape.nub(for: body, at: .bottomRight)
        XCTAssertEqual(start.body.maxX, body.maxX)
        XCTAssertEqual(start.body.minY, body.minY)
        let frames = NotchMorph.frames(from: start, to: .open(body: body, at: .bottomRight), motion: NotchMorph.open)
        for shape in frames.shapes {
            XCTAssertEqual(shape.body.maxX, body.maxX, accuracy: 0.001)
            XCTAssertEqual(shape.body.minY, body.minY, accuracy: 0.001)
        }
        let closing = NotchMorph.frames(from: .open(body: body, at: .bottomRight), to: start, motion: NotchMorph.close)
        XCTAssertEqual(closing.shapes.last, start)
    }

    // MARK: Docking

    func testADockedWindowAtASideEdgeHasOnlyTheControlsBand() {
        let clearance = DockGeometry.clearance(notch: nil, menuBarHeight: 33, position: .left)
        XCTAssertEqual(clearance, DockGeometry.controlBand)
        let layout = DockGeometry.layout(windowSize: CGSize(width: 800, height: 500), screen: screen,
                                         clearance: clearance, minimumBodyWidth: DockGeometry.minimumBodyWidth(notch: nil),
                                         position: .left, visible: visible)
        XCTAssertEqual(layout.body.minX, screen.minX)
        XCTAssertEqual(layout.window.minX, DockGeometry.sideInset)
        XCTAssertEqual(layout.band.height, clearance)
        XCTAssertEqual(layout.body.minY, layout.window.minY - DockGeometry.bottomInset)
        XCTAssertEqual(layout.body.midY, visible.midY, accuracy: 0.5)
        XCTAssertTrue(layout.body.contains(layout.window))
    }

    func testADockedWindowInACornerReachesBothEdges() {
        let layout = DockGeometry.layout(windowSize: CGSize(width: 800, height: 500), screen: screen, clearance: 32,
                                         minimumBodyWidth: 104, position: .bottomRight, visible: visible)
        XCTAssertEqual(layout.body.maxX, screen.maxX)
        XCTAssertEqual(layout.body.minY, visible.minY, "the window sits above the Dock, which would cover it")
        XCTAssertEqual(layout.window.minY, visible.minY + DockGeometry.bottomInset)
        XCTAssertEqual(layout.body.maxY, layout.window.maxY + 32)
        // macOS nudged the window up and in: the body still reaches the corner.
        let nudged = DockGeometry.layout(around: layout.window.offsetBy(dx: -20, dy: 12), screen: screen,
                                         minimumBodyWidth: 104, position: .bottomRight, clearance: 32, visible: visible)
        XCTAssertEqual(nudged.body.maxX, screen.maxX)
        XCTAssertEqual(nudged.body.minY, visible.minY)
        XCTAssertEqual(nudged.body.maxY, nudged.window.maxY + 32)
    }

    func testTheNotchDockLayoutIsUnchanged() {
        let notch = CGSize(width: 200, height: 32)
        let window = CGSize(width: 900, height: 600)
        let minimum = DockGeometry.minimumBodyWidth(notch: notch)
        XCTAssertEqual(DockGeometry.layout(windowSize: window, screen: screen, clearance: 33, minimumBodyWidth: minimum),
                       DockGeometry.layout(windowSize: window, screen: screen, clearance: 33, minimumBodyWidth: minimum,
                                           position: .notch, visible: visible))
    }

    // MARK: Preferences

    func testSavedSettingsWithoutAPositionOpenAtTheNotch() throws {
        let old = try JSONDecoder().decode(DropyPreferences.self, from: Data(#"{"sizePreset":"wide"}"#.utf8))
        XCTAssertEqual(old.position, .notch)
        XCTAssertEqual(old.sizePreset, .wide)
        let unknown = try JSONDecoder().decode(DropyPreferences.self, from: Data(#"{"position":"top"}"#.utf8))
        XCTAssertEqual(unknown.position, .notch, "a position from a newer build falls back")
        var preferences = DropyPreferences()
        preferences.position = .bottomLeft
        let round = try JSONDecoder().decode(DropyPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(round.position, .bottomLeft)
    }
}
