import CoreGraphics
import Foundation
import XCTest
import DropyCore

final class CaptureGeometryTests: XCTestCase {
    func testMeasuredGeometryRejectsOldFramesAfterProportionalResize() {
        let pixels = CGSize(width: 1040, height: 824)
        let old = CaptureGeometry.measured(windowID: 1, pixelSize: pixels,
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 412), contentScale: 1, scaleFactor: 2)
        let resized = CGSize(width: 1040, height: 824)
        XCTAssertEqual(old?.windowSize, CGSize(width: 520, height: 412))
        let current = CaptureGeometry.measured(windowID: 1, pixelSize: pixels,
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 412), contentScale: 0.5, scaleFactor: 2)
        XCTAssertEqual(current?.windowSize, resized)
        XCTAssertNil(CaptureGeometry.measured(windowID: 1, pixelSize: pixels,
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), contentScale: 1, scaleFactor: 2))
        XCTAssertNil(CaptureGeometry.measured(windowID: 1, pixelSize: pixels,
            contentRect: nil, contentScale: 1, scaleFactor: 2))
    }

}
