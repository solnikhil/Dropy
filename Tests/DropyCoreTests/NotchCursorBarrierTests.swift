import XCTest
import CoreGraphics
import DropyCore

final class NotchCursorBarrierTests: XCTestCase {
    private let housing = CGRect(x: 751, y: 0, width: 208, height: 37.5)
    func testCrossingsStopAtTheApproachedShoulder() {
        XCTAssertEqual(NotchCursorBarrier.constrained(from: CGPoint(x: 740, y: 10), to: CGPoint(x: 970, y: 10), housing: housing), CGPoint(x: 750, y: 10))
        XCTAssertEqual(NotchCursorBarrier.constrained(from: CGPoint(x: 970, y: 10), to: CGPoint(x: 740, y: 10), housing: housing), CGPoint(x: 960, y: 10))
    }
    func testMovementBelowHousingAndAlongSameSideStaysNative() {
        XCTAssertNil(NotchCursorBarrier.constrained(from: CGPoint(x: 740, y: 40), to: CGPoint(x: 970, y: 40), housing: housing))
        XCTAssertNil(NotchCursorBarrier.constrained(from: CGPoint(x: 740, y: 10), to: CGPoint(x: 730, y: 10), housing: housing))
        XCTAssertNil(NotchCursorBarrier.constrained(from: CGPoint(x: 740, y: 10), to: CGPoint(x: 970, y: 50), housing: housing))
    }
    func testTranslatedDisplayUsesItsOwnHousing() {
        let translated = housing.offsetBy(dx: -1700, dy: -800)
        XCTAssertEqual(NotchCursorBarrier.constrained(from: CGPoint(x: -960, y: -790), to: CGPoint(x: -730, y: -790), housing: translated), CGPoint(x: -950, y: -790))
    }
}
