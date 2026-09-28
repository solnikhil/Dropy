import XCTest
import DropyCore

final class DismissalTests: XCTestCase {
    func testEscapeAlwaysCloses() {
        for behavior in DismissBehavior.allCases {
            XCTAssertTrue(behavior.closes(on: .escape))
        }
    }

    func testEachBehaviorClosesOnlyOnItsEvents() {
        XCTAssertTrue(DismissBehavior.clickOutside.closes(on: .clickOutside))
        XCTAssertFalse(DismissBehavior.clickOutside.closes(on: .pointerLeft))
        XCTAssertTrue(DismissBehavior.pointerLeave.closes(on: .pointerLeft))
        XCTAssertTrue(DismissBehavior.pointerLeave.closes(on: .clickOutside))
        XCTAssertFalse(DismissBehavior.manual.closes(on: .clickOutside))
        XCTAssertFalse(DismissBehavior.manual.closes(on: .pointerLeft))
    }
}
