import XCTest
import DropyCore

final class PickerKeyTests: XCTestCase {
    func testKeysMapToPickerActions() {
        XCTAssertEqual(PickerKey(keyCode: 125, characters: nil, commandControlOrOption: false), .move(1))
        XCTAssertEqual(PickerKey(keyCode: 126, characters: nil, commandControlOrOption: false), .move(-1))
        XCTAssertEqual(PickerKey(keyCode: 36, characters: "\r", commandControlOrOption: false), .choose)
        XCTAssertEqual(PickerKey(keyCode: 76, characters: "\u{3}", commandControlOrOption: false), .choose)
        XCTAssertEqual(PickerKey(keyCode: 18, characters: "1", commandControlOrOption: false), .row(0))
        XCTAssertEqual(PickerKey(keyCode: 25, characters: "9", commandControlOrOption: false), .row(8))
    }
    func testOtherKeysAndModifiedKeysPassThrough() {
        XCTAssertNil(PickerKey(keyCode: 29, characters: "0", commandControlOrOption: false))
        XCTAssertNil(PickerKey(keyCode: 0, characters: "a", commandControlOrOption: false))
        XCTAssertNil(PickerKey(keyCode: 49, characters: " ", commandControlOrOption: true))
        XCTAssertNil(PickerKey(keyCode: 18, characters: "1", commandControlOrOption: true))
        XCTAssertNil(PickerKey(keyCode: 125, characters: nil, commandControlOrOption: true))
    }
    func testHighlightStaysWithinTheList() {
        XCTAssertEqual(PickerKey.highlight(nil, moving: 1, count: 3), 0)
        XCTAssertEqual(PickerKey.highlight(nil, moving: -1, count: 3), 2)
        XCTAssertEqual(PickerKey.highlight(0, moving: 1, count: 3), 1)
        XCTAssertEqual(PickerKey.highlight(2, moving: 1, count: 3), 2)
        XCTAssertEqual(PickerKey.highlight(0, moving: -1, count: 3), 0)
        XCTAssertEqual(PickerKey.highlight(7, moving: 1, count: 3), 0)
        XCTAssertNil(PickerKey.highlight(nil, moving: 1, count: 0))
    }
}
