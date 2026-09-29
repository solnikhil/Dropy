import Foundation
import XCTest
import DropyCore

final class FrameComparisonTests: XCTestCase {
    private func compare(_ a: [UInt8], stride sa: Int, _ b: [UInt8], stride sb: Int,
                         bytesPerRow: Int, rows: Int) -> Bool {
        a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in
                FrameComparison.identical(pa.baseAddress!, rowStride: sa, pb.baseAddress!,
                                          rowStride: sb, bytesPerRow: bytesPerRow, rows: rows)
            }
        }
    }

    func testIgnoresRowPaddingButCatchesOnePixelChange() {
        // Two rows of 8 image bytes; the first buffer pads each row to 12 bytes.
        let padded: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 99, 99, 99, 99,
                               9, 10, 11, 12, 13, 14, 15, 16, 0, 0, 0, 0]
        let tight: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        XCTAssertTrue(compare(padded, stride: 12, tight, stride: 8, bytesPerRow: 8, rows: 2))
        var changed = tight
        changed[15] = 0
        XCTAssertFalse(compare(padded, stride: 12, changed, stride: 8, bytesPerRow: 8, rows: 2))
    }

    func testRejectsRowsWiderThanStride() {
        let bytes = [UInt8](repeating: 0, count: 16)
        XCTAssertFalse(compare(bytes, stride: 8, bytes, stride: 8, bytesPerRow: 12, rows: 1))
    }

    func testRejectsNegativeSizesAndOverflow() {
        let bytes = [UInt8](repeating: 0, count: 16)
        XCTAssertFalse(compare(bytes, stride: 8, bytes, stride: 8, bytesPerRow: -1, rows: 1))
        XCTAssertFalse(compare(bytes, stride: -8, bytes, stride: 8, bytesPerRow: 4, rows: 1))
        XCTAssertFalse(compare(bytes, stride: 8, bytes, stride: 8, bytesPerRow: 4, rows: -1))
        XCTAssertFalse(compare(bytes, stride: 8, bytes, stride: 8,
                               bytesPerRow: 4, rows: Int.max))
    }
    func testOpaqueComparisonIgnoresOnlyAlpha() {
        let a: [UInt8] = [0, 0, 0, 1, 10, 20, 30, 255]
        let alpha: [UInt8] = [0, 0, 0, 14, 10, 20, 30, 3]
        let color: [UInt8] = [1, 0, 0, 14, 10, 20, 30, 3]
        a.withUnsafeBytes { first in
            alpha.withUnsafeBytes { second in
                XCTAssertFalse(FrameComparison.identical(first.baseAddress!, rowStride: 8, second.baseAddress!, rowStride: 8, bytesPerRow: 8, rows: 1))
                XCTAssertTrue(FrameComparison.identical(first.baseAddress!, rowStride: 8, second.baseAddress!, rowStride: 8, bytesPerRow: 8, rows: 1, ignoringAlpha: true))
            }
            color.withUnsafeBytes { second in
                XCTAssertFalse(FrameComparison.identical(first.baseAddress!, rowStride: 8, second.baseAddress!, rowStride: 8, bytesPerRow: 8, rows: 1, ignoringAlpha: true))
            }
        }
    }

}
