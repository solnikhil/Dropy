import XCTest
import DropyCore

final class PinnedAppTests: XCTestCase {
    func testAWindowIsShownWithoutLaunchingAnything() {
        XCTAssertEqual(PinnedAppPlan.next(installed: true, hasWindow: true, asked: false, waited: 0), .select)
        // A window from an app that was since uninstalled is still the app's window.
        XCTAssertEqual(PinnedAppPlan.next(installed: false, hasWindow: true, asked: false, waited: 0), .select)
    }

    func testOpensOnceThenWaitsThenGivesUpWithAReason() {
        XCTAssertEqual(PinnedAppPlan.next(installed: true, hasWindow: false, asked: false, waited: 0), .open)
        XCTAssertEqual(PinnedAppPlan.next(installed: true, hasWindow: false, asked: true, waited: 1), .wait)
        XCTAssertEqual(PinnedAppPlan.next(installed: true, hasWindow: false, asked: true,
                                          waited: PinnedAppPlan.windowTimeout), .giveUp(.noWindow))
        XCTAssertEqual(PinnedAppPlan.next(installed: true, hasWindow: true, asked: true, waited: 5), .select)
    }

    func testMissingAppIsReportedNotLaunched() {
        XCTAssertEqual(PinnedAppPlan.next(installed: false, hasWindow: false, asked: false, waited: 0),
                       .giveUp(.notInstalled))
        XCTAssertTrue(PinnedAppProblem.noWindow.message(appName: "Notes").contains("Open one in Notes"))
    }

    func testPinnedAppWinsOverOpenBehavior() throws {
        var preferences = DropyPreferences(openBehavior: .lastUsed, lastUsedBundleIdentifier: "com.apple.Safari")
        XCTAssertEqual(preferences.openTargetBundleIdentifier, "com.apple.Safari")
        preferences.pinnedBundleIdentifier = "com.apple.Notes"
        XCTAssertEqual(preferences.openTargetBundleIdentifier, "com.apple.Notes")
        preferences.pinnedBundleIdentifier = nil
        preferences.openBehavior = .picker
        XCTAssertNil(preferences.openTargetBundleIdentifier)
        // Saved before pinning existed: nothing pinned.
        let saved = Data(#"{"trigger":"notchHover","openBehavior":"direct","selectedBundleIdentifier":"com.apple.TextEdit"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(DropyPreferences.self, from: saved).pinnedBundleIdentifier)
        preferences.pinnedBundleIdentifier = "com.apple.Notes"
        XCTAssertEqual(try JSONDecoder().decode(DropyPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }
}
