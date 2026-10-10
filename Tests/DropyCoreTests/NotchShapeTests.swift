import XCTest
import CoreGraphics
import DropyCore

final class NotchShapeTests: XCTestCase {
    private let canvas = CGSize(width: 928, height: 540)

    private func elements(_ path: CGPath) -> [CGPathElementType] {
        var types: [CGPathElementType] = []
        path.applyWithBlock { types.append($0.pointee.type) }
        return types
    }

    func testNotchAndOpenOutlinesMorphPointByPoint() {
        let notch = NotchShape.notch(size: CGSize(width: 208, height: 37.5), in: canvas)
        let open = NotchShape.open(body: CGRect(origin: .zero, size: canvas))
        XCTAssertEqual(elements(notch.fillPath), elements(open.fillPath))
        XCTAssertEqual(elements(notch.strokePath), elements(open.strokePath))
        // A degenerate size keeps the same structure too (radii clamp, nothing is dropped).
        let tiny = NotchShape(body: CGRect(x: 10, y: 10, width: 2, height: 2), bottomRadius: 30, earRadius: 30)
        XCTAssertEqual(elements(tiny.fillPath), elements(open.fillPath))
    }

    func testOpenHangsFromTheTopEdgeAndTheNotchFromItsCenter() {
        let body = CGRect(x: 30, y: 30, width: canvas.width - 60, height: canvas.height - 30)
        // The ears reach out beside the body along the top edge.
        XCTAssertEqual(NotchShape.open(body: body).fillPath.boundingBoxOfPath,
                       body.insetBy(dx: -NotchShape.openEarRadius, dy: 0))
        let notch = NotchShape.notch(size: CGSize(width: 208, height: 37.5), in: canvas).fillPath.boundingBoxOfPath
        XCTAssertEqual(notch.maxY, canvas.height)
        XCTAssertEqual(notch.midX, canvas.width / 2)
        XCTAssertEqual(notch.height, 37.5)
    }
}
