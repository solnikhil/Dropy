import XCTest
import CoreGraphics
import DropyCore

final class WindowPickerLayoutTests: XCTestCase {
    func testChooserKeepsItsReadingSizeOnLargeDisplays() {
        XCTAssertEqual(WindowPickerLayout.size(available: CGSize(width: 3440, height: 1440)),
                       CGSize(width: 520, height: 560))
    }
    func testSmallDisplaysKeepMarginsAndScrollInsteadOfOverflowing() {
        XCTAssertEqual(WindowPickerLayout.size(available: CGSize(width: 480, height: 400)),
                       CGSize(width: 448, height: 368))
        XCTAssertEqual(WindowPickerLayout.size(available: .zero), CGSize(width: 1, height: 1))
    }
    func testStandardChooserHasRoomForSixRows() {
        let rows = 6 * WindowPickerLayout.rowHeight + 5 * WindowPickerLayout.rowSpacing
        XCTAssertTrue(rows <= WindowPickerLayout.preferredSize.height - 246)
    }
}
