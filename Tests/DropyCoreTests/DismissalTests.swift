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

    func testTheSystemTakingTheScreenAlwaysCloses() {
        for event in [DismissEvent.desktopChanged, .missionControl, .sessionEnded, .displayChanged] {
            XCTAssertTrue(event.isSystemChange)
            for behavior in DismissBehavior.allCases {
                XCTAssertTrue(behavior.closes(on: event), "\(behavior) closes on \(event), even manual")
            }
        }
        XCTAssertFalse(DismissEvent.escape.isSystemChange)
        XCTAssertFalse(DismissEvent.clickOutside.isSystemChange)
    }
}
