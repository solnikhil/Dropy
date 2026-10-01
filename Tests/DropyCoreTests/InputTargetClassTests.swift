import Foundation
import XCTest
import DropyCore

final class InputTargetClassTests: XCTestCase {
    private func trial(_ route: InputRoute, _ focus: FocusState, _ outcome: InputTrial.Outcome,
                       target: InputTargetClass?) -> InputTrial {
        InputTrial(route: route, kind: .pointerClick, condition: .visible, focus: focus, outcome: outcome,
                   sideEffects: [], target: target)
    }

    /// Safari, 2026-09-30: pressing page buttons passed; placing a caret did nothing.
    private var safariLike: InputCapabilities {
        InputCapabilities(trials: [FocusState.otherWindowKey, .appInactive].flatMap { focus in
            [trial(.accessibility, focus, .pass, target: .pressable),
             trial(.accessibility, focus, .noEffect, target: .text)]
        })
    }

    func testEachElementClassIsVerifiedSeparately() {
        XCTAssertEqual(safariLike.verdict(.accessibility, .pointerClick, .visible, target: .pressable), .verified)
        XCTAssertEqual(safariLike.verdict(.accessibility, .pointerClick, .visible, target: .text), .unreliable)
        XCTAssertEqual(safariLike.verdict(.accessibility, .pointerClick, .visible, target: .other), .untested)
        // Without a class, mixed evidence never verifies.
        XCTAssertEqual(safariLike.verdict(.accessibility, .pointerClick, .visible), .unreliable)
        XCTAssertEqual(safariLike.verifiedTargets(.pointerClick, in: .visible, policy: .preview), [.pressable])
        XCTAssertTrue(safariLike.verifiedKinds(in: .visible, policy: .preview).contains(.pointerClick))
    }

    func testThePlannerSendsOnlyForTheVerifiedClass() {
        func decide(_ target: InputTargetClass?) -> InputDecision {
            InputPlanner.decide(.pointerClick, selectedWindowID: 7, resolution: .exact(windowID: 7), condition: .visible,
                                capabilities: safariLike, policy: .preview, target: target)
        }
        XCTAssertEqual(decide(.pressable), .send(.accessibility, handBackFocus: false))
        XCTAssertEqual(decide(.text), .refuse(.notVerified))
        XCTAssertEqual(decide(.other), .refuse(.notVerified))
    }

    func testUntaggedTrialsCountForEveryClassSoTheyCanOnlyFailIt() {
        let trials = InputCapabilities(trials: [FocusState.otherWindowKey, .appInactive].flatMap { focus in
            [trial(.accessibility, focus, .pass, target: .pressable), trial(.accessibility, focus, .noEffect, target: nil)]
        })
        XCTAssertEqual(trials.verdict(.accessibility, .pointerClick, .visible, target: .pressable), .unreliable)
        let legacy = InputCapabilities(trials: [FocusState.otherWindowKey, .appInactive].map {
            trial(.windowTargetedEvent, $0, .pass, target: nil)
        })
        XCTAssertEqual(legacy.verdict(.windowTargetedEvent, .pointerClick, .visible, target: .text), .verified)
    }

    func testTargetRoundTripsAndOlderEvidenceDecodes() throws {
        let tagged = trial(.accessibility, .appInactive, .pass, target: .pressable)
        let decoded = try JSONDecoder().decode(InputTrial.self, from: JSONEncoder().encode(tagged))
        XCTAssertEqual(decoded, tagged)
        let old = #"{"route":"accessibility","kind":"pointerClick","condition":"visible","focus":"appInactive","outcome":"pass","sideEffects":[]}"#
        XCTAssertNil(try JSONDecoder().decode(InputTrial.self, from: Data(old.utf8)).target)
    }
}
