import XCTest
import DropyCore

final class NotchReachTests: XCTestCase {
    /// The 14-inch MacBook Pro notch measured on 2026-10-02: x 751–959, 37.5 points tall.
    private let notch = CGRect(x: 751, y: 1074.5, width: 208, height: 37.5)

    func testPointerPushedUpAtTheNotchIsInside() {
        let reach = NotchActivation(housing: notch)
        // Held at the lower edge or slid under the camera, either way it counts.
        XCTAssertEqual(reach.region(at: CGPoint(x: 855, y: 1074)), .base)
        XCTAssertEqual(reach.region(at: CGPoint(x: 855, y: 1070)), .base)
        XCTAssertEqual(reach.region(at: CGPoint(x: 855, y: 1100)), .base)
        XCTAssertEqual(reach.region(at: CGPoint(x: 855, y: 1112)), .base)
    }

    func testReachStaysNearTheNotch() {
        let reach = NotchActivation(housing: notch)
        XCTAssertNil(reach.region(at: CGPoint(x: 855, y: 1060)))
        XCTAssertNil(reach.region(at: CGPoint(x: 700, y: 1100)))
        XCTAssertNil(reach.region(at: CGPoint(x: 1000, y: 1100)))
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
