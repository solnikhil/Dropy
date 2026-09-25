import XCTest
import DropyCore

final class WindowIdentityTests: XCTestCase {
    func testOnlyTheOriginalProcessAndWindowMatch() {
        let launched = Date(timeIntervalSince1970: 1_000)
        let original = WindowIdentity(processID: 100, processLaunchDate: launched,
                                      windowID: 42, bundleIdentifier: "org.example.editor")
        XCTAssertTrue(original.matches(original))
        XCTAssertFalse(original.matches(WindowIdentity(processID: 101, processLaunchDate: launched,
                                                       windowID: 42, bundleIdentifier: "org.example.editor")))
        XCTAssertFalse(original.matches(WindowIdentity(processID: 100, processLaunchDate: launched,
                                                       windowID: 43, bundleIdentifier: "org.example.editor")))
        XCTAssertFalse(original.matches(WindowIdentity(processID: 100,
                                                       processLaunchDate: launched.addingTimeInterval(10),
                                                       windowID: 42, bundleIdentifier: "org.example.editor")))
        XCTAssertFalse(original.matches(WindowIdentity(processID: 100, processLaunchDate: launched,
                                                       windowID: 42, bundleIdentifier: "org.example.other")))
    }
}
