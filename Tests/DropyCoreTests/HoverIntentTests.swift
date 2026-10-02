import XCTest
import CoreGraphics
import DropyCore

final class HoverIntentTests: XCTestCase {
    private let notch = CGRect(x: 751, y: 1074.5, width: 208, height: 37.5)

    func testRestingUnderTheNotchOpens() {
        let zone = OverlayGeometry.notchReach(notch)
        XCTAssertTrue(HoverIntent.confirms(enteredAt: CGPoint(x: 850, y: 1074), now: CGPoint(x: 858, y: 1072), zone: zone))
    }

    func testPassingThroughDoesNotOpen() {
        let zone = OverlayGeometry.notchReach(notch)
        // Swept sideways along the strip under the notch.
        XCTAssertFalse(HoverIntent.confirms(enteredAt: CGPoint(x: 760, y: 1072), now: CGPoint(x: 900, y: 1072), zone: zone))
        // Gone again by the time the delay ends.
        XCTAssertFalse(HoverIntent.confirms(enteredAt: CGPoint(x: 850, y: 1072), now: CGPoint(x: 850, y: 1000), zone: zone))
    }

    func testMenuBarBesideTheNotchIsNotPartOfTheZone() {
        // Sliding along the menu bar, macOS jumps the pointer across the notch and it
        // lands just beside it.
        let zone = OverlayGeometry.notchReach(notch)
        XCTAssertFalse(zone.contains(CGPoint(x: 745, y: 1100)))
        XCTAssertFalse(zone.contains(CGPoint(x: 965, y: 1100)))
        XCTAssertTrue(zone.contains(CGPoint(x: 855, y: 1070)))
    }
}
