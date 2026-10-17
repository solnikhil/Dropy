import XCTest
import DropyCore

final class OverlayOpeningTests: XCTestCase {
    func testVirtualDisplayAnnouncementDoesNotDismissOpening() {
        var tracker = OverlayDesktopTracker(spaceID: 10)
        XCTAssertFalse(tracker.observe(nil))
        XCTAssertEqual(tracker.spaceID, 10)
        XCTAssertFalse(tracker.observe(10))
        XCTAssertTrue(tracker.observe(11))
        XCTAssertEqual(tracker.spaceID, 11)
    }

    func testInitiallyUnknownSpaceEstablishesBaselineWithoutClosing() {
        var tracker = OverlayDesktopTracker()
        XCTAssertFalse(tracker.observe(nil))
        XCTAssertFalse(tracker.observe(40))
        XCTAssertFalse(tracker.observe(nil))
        XCTAssertFalse(tracker.observe(40))
        XCTAssertTrue(tracker.observe(41))
    }

    func testShortcutOpensHereInsteadOfClosingAnInvisibleOverlayElsewhere() {
        let old = OverlayLocation(displayID: 1, spaceID: 10)
        let here = OverlayLocation(displayID: 1, spaceID: 20)
        XCTAssertEqual(OverlayOpeningAction.resolve(isOpen: true, opened: old, requested: here), .relocate)
        XCTAssertEqual(OverlayOpeningAction.resolve(isOpen: true, opened: here, requested: here), .close)
        XCTAssertEqual(OverlayOpeningAction.resolve(isOpen: false, opened: old, requested: here), .open)
    }

    func testUnknownSpaceDoesNotInventARelocation() {
        let known = OverlayLocation(displayID: 1, spaceID: 10)
        let unknown = OverlayLocation(displayID: 1, spaceID: nil)
        XCTAssertEqual(OverlayOpeningAction.resolve(isOpen: true, opened: known, requested: unknown), .close)
        XCTAssertEqual(OverlayOpeningAction.resolve(isOpen: true, opened: unknown, requested: known), .close)
    }

    func testShortcutRelocatesAcrossPhysicalDisplaysRegardlessOfSpaceFacts() {
        XCTAssertEqual(OverlayOpeningAction.resolve(isOpen: true,
            opened: OverlayLocation(displayID: 1, spaceID: nil),
            requested: OverlayLocation(displayID: 2, spaceID: nil)), .relocate)
    }
}
