import XCTest
import DropyCore

final class ReleaseVersionTests: XCTestCase {
    func testNumericVersionOrderingAndBuildMetadata() {
        XCTAssertTrue(ReleaseVersion("1.10.0")! > ReleaseVersion("1.9.9")!)
        XCTAssertEqual(ReleaseVersion("v1.2"), ReleaseVersion("1.2.0"))
        XCTAssertEqual(ReleaseVersion("1.2.3+build.9"), ReleaseVersion("1.2.3+build.10"))
        XCTAssertTrue(ReleaseVersion("2.0.0-beta")! > ReleaseVersion("1.99.99")!)
    }
    func testPrereleasePrecedence() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
                       "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"].map { ReleaseVersion($0)! }
        XCTAssertEqual(ordered.sorted(), ordered)
        XCTAssertTrue(ReleaseVersion("1.0.0-999999999999999999999")! < ReleaseVersion("1.0.0-1000000000000000000000")!)
    }
    func testMalformedVersionsAreRejected() {
        for value in ["", "1", "01.2.3", "1.02.3", "1.2.3.4", "1.2.3-", "1.2.3-beta.01",
                      "1.2.3+", "1.2.3+a+b", "1.2.3-../x", "release-v1.2.3", "١.2.3",
                      "999999999999999999999.0.0"] {
            XCTAssertNil(ReleaseVersion(value))
        }
    }
}
