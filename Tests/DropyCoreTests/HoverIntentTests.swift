import XCTest
import CoreGraphics
import DropyCore

final class HoverIntentTests: XCTestCase {
    private let point = CGPoint(x: 850, y: 1072)
    func testEachEdgeOpensAfterResting() {
        for region in [NotchActivation.Region.base, .left, .right] {
            var session = NotchHoverSession()
            XCTAssertFalse(session.sample(point: point, region: region, at: 0))
            XCTAssertFalse(session.sample(point: point, region: region, at: 0.1))
            XCTAssertTrue(session.sample(point: point, region: region, at: 0.23))
        }
    }
    func testDriftThenRestRetriesWithoutExit() {
        var session = NotchHoverSession()
        XCTAssertFalse(session.sample(point: point, region: .base, at: 0))
        let drift = CGPoint(x: 900, y: point.y)
        XCTAssertFalse(session.sample(point: drift, region: .base, at: 0.23))
        XCTAssertFalse(session.sample(point: drift, region: .base, at: 0.3))
        XCTAssertTrue(session.sample(point: drift, region: .base, at: 0.46))
    }
    func testCrossingToAnotherEdgeRestartsIntent() {
        var session = NotchHoverSession()
        XCTAssertFalse(session.sample(point: point, region: .right, at: 0))
        XCTAssertFalse(session.sample(point: point, region: .left, at: 0.2))
        XCTAssertFalse(session.sample(point: point, region: .left, at: 0.3))
        XCTAssertTrue(session.sample(point: point, region: .left, at: 0.43))
    }
    func testExitCancelsIntent() {
        var session = NotchHoverSession()
        XCTAssertFalse(session.sample(point: point, region: .base, at: 0))
        XCTAssertFalse(session.sample(point: point, region: nil, at: 0.2))
        XCTAssertNil(session.deadline)
        XCTAssertFalse(session.sample(point: point, region: .base, at: 0.3))
    }
    func testCloseOutsideDoesNotRequireAnExtraExit() {
        var session = NotchHoverSession()
        session.closed(at: 1, pointerInside: false)
        XCTAssertFalse(session.sample(point: point, region: .base, at: 1.1))
        XCTAssertNotNil(session.deadline)
        XCTAssertTrue(session.sample(point: point, region: .base, at: 1.63))
    }
    func testCloseInsideRequiresExitAndFreshIntent() {
        var session = NotchHoverSession()
        session.closed(at: 1, pointerInside: true)
        XCTAssertFalse(session.sample(point: point, region: .base, at: 2))
        XCTAssertNil(session.deadline)
        XCTAssertFalse(session.sample(point: point, region: nil, at: 2.1))
        XCTAssertFalse(session.sample(point: point, region: .base, at: 2.2))
        XCTAssertTrue(session.sample(point: point, region: .base, at: 2.43))
    }
    func testExactLowerEdgeIsReachableWithoutEnteringCameraInterior() {
        let housing = CGRect(x: 751, y: 1074.5, width: 208, height: 37.5)
        let activation = NotchActivation(housing: housing)
        let edge = CGPoint(x: housing.midX, y: housing.minY)
        XCTAssertEqual(activation.region(at: edge), .base)
        XCTAssertTrue(activation.trackingFrame.contains(edge))
        XCTAssertNil(activation.region(at: CGPoint(x: edge.x, y: edge.y + 0.5)))
        var session = NotchHoverSession()
        XCTAssertFalse(session.sample(point: edge, region: activation.region(at: edge), at: 0))
        XCTAssertTrue(session.sample(point: edge, region: activation.region(at: edge), at: 0.23))
    }
    func testBaseAndShouldersShareOneTrackingSurface() {
        let housing = CGRect(x: -600, y: 400, width: 200, height: 40)
        let activation = NotchActivation(housing: housing)
        for point in [CGPoint(x: -605, y: 420), CGPoint(x: -395, y: 420), CGPoint(x: -500, y: 400)] {
            XCTAssertTrue(activation.trackingFrame.contains(point))
            XCTAssertNotNil(activation.region(at: point))
        }
        XCTAssertNil(activation.region(at: CGPoint(x: -500, y: 420)))
    }
    func testTranslatedHousingIncludesOnlyReachableEdges() {
        let activation = NotchActivation(housing: CGRect(x: -600, y: 400, width: 200, height: 40))
        XCTAssertEqual(activation.region(at: CGPoint(x: -605, y: 420)), .left)
        XCTAssertEqual(activation.region(at: CGPoint(x: -395, y: 420)), .right)
        XCTAssertEqual(activation.region(at: CGPoint(x: -500, y: 395)), .base)
        XCTAssertNil(activation.region(at: CGPoint(x: -500, y: 420)))
        XCTAssertNil(activation.region(at: CGPoint(x: -500, y: 380)))
    }
}
