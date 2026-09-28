import Foundation
import XCTest
import DropyCore

final class InputCapabilityTests: XCTestCase {
    private func trial(_ route: InputRoute, _ kind: InputKind, in condition: SourceCondition = .parked,
                       _ focus: FocusState, _ outcome: InputTrial.Outcome) -> InputTrial {
        InputTrial(route: route, kind: kind, condition: condition, focus: focus, outcome: outcome)
    }

    /// Shaped like the 2026-09-29 fixture probe: AX text passes everywhere, process-targeted
    /// keys land in the key window, window-targeted clicks pass, menu shortcuts follow the key window.
    private var evidence: InputCapabilities {
        var trials: [InputTrial] = []
        for focus in FocusState.allCases {
            trials.append(trial(.accessibility, .text, focus, .pass))
            trials.append(trial(.accessibility, .pointerClick, focus, .pass))
            trials.append(trial(.windowTargetedEvent, .pointerClick, focus, .pass))
            trials.append(trial(.processEvent, .text, focus, focus == .targetKey ? .pass : .wrongWindow))
            trials.append(trial(.accessibility, .keyShortcut, focus,
                                focus == .targetKey ? .pass : focus == .otherWindowKey ? .wrongWindow : .noEffect))
            trials.append(trial(.processEvent, .pointerClick, focus, .noEffect))
            trials.append(trial(.activateAndPost, .pointerClick, focus, .notApplicable))
        }
        return InputCapabilities(trials: trials)
    }

    func testAnyWrongWindowTrialDisqualifiesARoute() {
        XCTAssertEqual(evidence.verdict(.processEvent, .text, .parked), .wrongWindowObserved)
        XCTAssertEqual(evidence.verdict(.accessibility, .keyShortcut, .parked), .wrongWindowObserved)
        XCTAssertEqual(evidence.verdict(.accessibility, .text, .parked), .verified)
        XCTAssertEqual(evidence.verdict(.processEvent, .pointerClick, .parked), .unreliable)
        XCTAssertEqual(evidence.verdict(.activateAndPost, .pointerClick, .parked), .notApplicable)
        XCTAssertEqual(evidence.verdict(.accessibility, .text, .otherSpace), .untested)
    }

    func testPassingOnlyWhileTheTargetIsKeyIsNotVerified() {
        let onlyKey = InputCapabilities(trials: [trial(.processEvent, .scroll, .targetKey, .pass)])
        XCTAssertEqual(onlyKey.verdict(.processEvent, .scroll, .parked), .unreliable)
        let missingInactive = InputCapabilities(trials: [trial(.accessibility, .scroll, .targetKey, .pass),
                                                         trial(.accessibility, .scroll, .otherWindowKey, .pass)])
        XCTAssertEqual(missingInactive.verdict(.accessibility, .scroll, .parked), .unreliable)
    }

    func testNeverSendsToAnAmbiguousOrChangedTarget() {
        let policy = InputPolicy(allowsPrivateInterfaces: true, allowsFocusChanges: true)
        XCTAssertEqual(InputPlanner.decide(.text, selectedWindowID: 9, resolution: .ambiguous, condition: .parked,
                                           capabilities: evidence, policy: policy), .refuse(.ambiguousTarget))
        XCTAssertEqual(InputPlanner.decide(.text, selectedWindowID: 9, resolution: .exact(windowID: 10), condition: .parked,
                                           capabilities: evidence, policy: policy), .refuse(.targetChanged))
        XCTAssertEqual(InputPlanner.decide(.text, selectedWindowID: 9, resolution: .unreachable(.onOtherSpace),
                                           condition: .otherSpace, capabilities: evidence, policy: policy),
                       .refuse(.targetUnreachable(.onOtherSpace)))
    }

    func testChoosesOnlyVerifiedAllowedRoutes() {
        let publicOnly = InputPolicy()
        XCTAssertEqual(InputPlanner.decide(.text, selectedWindowID: 9, resolution: .exact(windowID: 9), condition: .parked,
                                           capabilities: evidence, policy: publicOnly), .send(.accessibility, handBackFocus: false))
        XCTAssertEqual(InputPlanner.decide(.pointerClick, selectedWindowID: 9, resolution: .exact(windowID: 9),
                                           condition: .parked, capabilities: evidence, policy: publicOnly),
                       .send(.accessibility, handBackFocus: false))
        // A shortcut's only allowed route went to the wrong window: refuse, don't guess.
        XCTAssertEqual(InputPlanner.decide(.keyShortcut, selectedWindowID: 9, resolution: .exact(windowID: 9),
                                           condition: .parked, capabilities: evidence, policy: publicOnly),
                       .refuse(.wrongWindowRisk))
        XCTAssertEqual(InputPlanner.decide(.drag, selectedWindowID: 9, resolution: .exact(windowID: 9),
                                           condition: .parked, capabilities: evidence, policy: publicOnly),
                       .refuse(.notVerified))
        // The private window-targeted route is used only when the policy allows it.
        let clickOnlyWindowTargeted = InputCapabilities(trials: FocusState.allCases.map {
            trial(.windowTargetedEvent, .scroll, $0, .pass)
        })
        XCTAssertEqual(InputPlanner.decide(.scroll, selectedWindowID: 9, resolution: .exact(windowID: 9), condition: .parked,
                                           capabilities: clickOnlyWindowTargeted, policy: publicOnly), .refuse(.notVerified))
        XCTAssertEqual(InputPlanner.decide(.scroll, selectedWindowID: 9, resolution: .exact(windowID: 9), condition: .parked,
                                           capabilities: clickOnlyWindowTargeted,
                                           policy: InputPolicy(allowsPrivateInterfaces: true)),
                       .send(.windowTargetedEvent, handBackFocus: false))
    }

    func testFocusChangingRouteRequiresHandback() {
        let activate = InputCapabilities(trials: FocusState.allCases.map { trial(.activateAndPost, .keyShortcut, in: .visible, $0, .pass) })
        XCTAssertEqual(InputPlanner.decide(.keyShortcut, selectedWindowID: 9, resolution: .exact(windowID: 9), condition: .visible,
                                           capabilities: activate, policy: InputPolicy()), .refuse(.notVerified))
        XCTAssertEqual(InputPlanner.decide(.keyShortcut, selectedWindowID: 9, resolution: .exact(windowID: 9), condition: .visible,
                                           capabilities: activate, policy: InputPolicy(allowsFocusChanges: true)),
                       .send(.activateAndPost, handBackFocus: true))
        XCTAssertTrue(InputRoute.activateAndPost.movesPointer)
        XCTAssertTrue(InputRoute.windowTargetedEvent.usesPrivateInterfaces)
        XCTAssertFalse(InputRoute.accessibility.usesPrivateInterfaces)
    }

    func testSupportLabelNamesVerifiedKindsOnly() {
        XCTAssertEqual(InputPlanner.support(in: .parked, capabilities: evidence, policy: InputPolicy()),
                       .interactive([.text, .pointerClick]))
        XCTAssertEqual(InputPlanner.support(in: .minimized, capabilities: evidence, policy: InputPolicy()), .viewOnly)
        XCTAssertEqual(InputPlanner.support(in: .parked, capabilities: InputCapabilities(trials: []), policy: InputPolicy()),
                       .viewOnly)
    }

    func testTrialsRoundTrip() throws {
        let original = trial(.windowTargetedEvent, .scroll, .appInactive, .pass)
        XCTAssertEqual(try JSONDecoder().decode(InputTrial.self, from: JSONEncoder().encode(original)), original)
    }
}
