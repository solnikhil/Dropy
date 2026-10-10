import XCTest
import CoreGraphics
import DropyCore

final class GeometryTests: XCTestCase {
    func testOverlayIsTopCenteredAndClamped() {
        let screen = CGRect(x: 100, y: 50, width: 1000, height: 700)
        let frame = OverlayGeometry.frame(on: screen, preferredSize: .init(width: 1200, height: 400))
        XCTAssertEqual(frame, CGRect(x: 100, y: 350, width: 1000, height: 400))
    }

    func testFractionalCanvasKeepsScreenTopAndContainsBody() {
        let canvas = CGRect(x: 611.125, y: 732.375, width: 487.75, height: 379.625)
        for scale: CGFloat in [1, 2] {
            let aligned = OverlayGeometry.pixelAligned(canvas, scale: scale)
            XCTAssertEqual(aligned.maxY, 1112)
            XCTAssertTrue(aligned.minX <= canvas.minX && aligned.maxX >= canvas.maxX)
            XCTAssertTrue(aligned.minY <= canvas.minY)
            XCTAssertEqual((aligned.minX * scale).rounded(), aligned.minX * scale)
        }
    }

    func testFitRejectsLetterboxClicks() {
        let transform = ContentTransform(sourceRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                                         destinationRect: CGRect(x: 0, y: 0, width: 400, height: 400),
                                         mode: .fit)
        XCTAssertNil(transform.sourcePoint(for: CGPoint(x: 200, y: 50)))
        XCTAssertEqual(transform.sourcePoint(for: CGPoint(x: 200, y: 200)), CGPoint(x: 200, y: 100))
    }

    func testFillMapsOnlyVisibleCrop() {
        let transform = ContentTransform(sourceRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                                         destinationRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                                         mode: .fill)
        XCTAssertEqual(transform.sourcePoint(for: CGPoint(x: 0, y: 100)), CGPoint(x: 100, y: 100))
        XCTAssertEqual(transform.sourcePoint(for: CGPoint(x: 199, y: 100)), CGPoint(x: 299, y: 100))
    }

    func testSelectedRegionMaintainsSourceOffset() {
        let transform = ContentTransform(sourceRect: CGRect(x: 300, y: 150, width: 200, height: 100),
                                         destinationRect: CGRect(x: 20, y: 20, width: 200, height: 100),
                                         mode: .selectedRegion)
        XCTAssertEqual(transform.sourcePoint(for: CGPoint(x: 120, y: 70)), CGPoint(x: 400, y: 200))
    }
}
