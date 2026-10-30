import XCTest
import DropyCore

final class AnimationCommandArgumentsTests: XCTestCase {
    func testOptionsDoNotBecomeTargetsAndCanAppearBeforeOrAfterThem() throws {
        let before = try AnimationCommandArguments(command: "render", arguments: ["--out", "preview.png", "balanced"])
        let after = try AnimationCommandArguments(command: "render", arguments: ["balanced", "--out", "preview.png"])
        XCTAssertEqual(before, after)
        XCTAssertEqual(before.positionals, ["balanced"])
        XCTAssertEqual(before.options["--out"], "preview.png")
        let named = try AnimationCommandArguments(command: "new", arguments: ["--from", "springy", "My", "Animation"])
        XCTAssertEqual(named.positionals, ["My", "Animation"])
        XCTAssertEqual(named.options["--from"], "springy")
    }

    func testMalformedOptionsFailBeforeTheCommandCanChangeFiles() {
        let cases: [(String, [String])] = [
            ("new", ["Draft", "--from"]), ("new", ["Draft", "--from", "--typo"]),
            ("render", ["balanced", "--out"]), ("check", ["balanced", "--typo"]),
            ("play", ["balanced", "--slow", "2", "--slow", "3"]),
            ("check", ["balanced", "springy"]), ("docs", ["unexpected"]),
        ]
        for (command, arguments) in cases {
            do {
                _ = try AnimationCommandArguments(command: command, arguments: arguments)
                XCTFail("Accepted malformed arguments for \(command): \(arguments)")
            } catch { }
        }
    }

    func testEndOfOptionsAndNegativeOptionValuesArePreserved() throws {
        let target = try AnimationCommandArguments(command: "check", arguments: ["--", "--draft.json"])
        XCTAssertEqual(target.positionals, ["--draft.json"])
        let slow = try AnimationCommandArguments(command: "play", arguments: ["--slow", "-inf", "balanced"])
        XCTAssertEqual(slow.options["--slow"], "-inf")
        let docs = try AnimationCommandArguments(command: "docs", arguments: ["--generic"])
        XCTAssertEqual(docs.options["--generic"], "")
    }
}
