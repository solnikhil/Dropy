import XCTest
import DropyCore

final class NotchReachTests: XCTestCase {
    /// The 14-inch MacBook Pro notch measured on 2026-10-02: x 751–959, 37.5 points tall.
    private let notch = CGRect(x: 751, y: 1074.5, width: 208, height: 37.5)

    func testPointerHeldBelowTheNotchIsInside() {
        let reach = OverlayGeometry.notchReach(notch)
        // Pushed up, the pointer stops at the notch's lower edge, not inside it.
        XCTAssertTrue(reach.contains(CGPoint(x: 855, y: 1074)))
        XCTAssertTrue(reach.contains(CGPoint(x: 855, y: 1070)))
        XCTAssertTrue(reach.contains(CGPoint(x: 855, y: 1100)))
    }

    func testReachStaysNearTheNotch() {
        let reach = OverlayGeometry.notchReach(notch)
        XCTAssertFalse(reach.contains(CGPoint(x: 855, y: 1060)))
        XCTAssertFalse(reach.contains(CGPoint(x: 700, y: 1100)))
        XCTAssertFalse(reach.contains(CGPoint(x: 1000, y: 1100)))
    }

    func testDefaultShortcutAvoidsDockHidingAndOldSettingsMoveToIt() throws {
        XCTAssertEqual(KeyShortcut.default.display, "⌃⌥D")
        XCTAssertFalse(KeyShortcut.default.modifiers == KeyShortcut.command | KeyShortcut.option)
        XCTAssertTrue(KeyShortcut.default.isAcceptable)
        XCTAssertFalse(KeyShortcut(keyCode: 2, modifiers: KeyShortcut.shift, display: "⇧D").isAcceptable)
        XCTAssertEqual(KeyShortcut.symbols(for: KeyShortcut.command | KeyShortcut.shift | KeyShortcut.control), "⌃⇧⌘")
        let saved = Data(#"{"trigger":"notchHover"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(DropyPreferences.self, from: saved).shortcut, .default)
        var preferences = DropyPreferences()
        preferences.shortcut = KeyShortcut(keyCode: 45, modifiers: KeyShortcut.control | KeyShortcut.command, display: "⌃⌘N")
        XCTAssertEqual(try JSONDecoder().decode(DropyPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }
}
