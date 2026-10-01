import CoreGraphics
import Foundation
import XCTest
import DropyCore

final class InteractivePreviewTests: XCTestCase {
    // A 800 x 440 pt window captured at 1176 x 646 px, shown in a 900 x 540 pt preview on a 2x display.
    private func mapping(_ mode: ContentMode) -> PreviewPointMapping {
        PreviewPointMapping(viewSize: CGSize(width: 900, height: 540), backingScale: 2,
                            capturePixelSize: CGSize(width: 1176, height: 646),
                            windowSize: CGSize(width: 800, height: 440), mode: mode)
    }

    func testFitMapsThroughTheDrawnImageAndRejectsLetterbox() throws {
        let fit = mapping(.fit)
        // The image fills the width: 1800 px / 1176 px; it is centred vertically.
        let centre = try XCTUnwrap(fit.windowPoint(for: CGPoint(x: 450, y: 270)))
        XCTAssertEqual(centre.x, 400, accuracy: 0.5)
        XCTAssertEqual(centre.y, 220, accuracy: 0.5)
        let corner = try XCTUnwrap(fit.windowPoint(for: CGPoint(x: 0.5, y: 270)))
        XCTAssertEqual(corner.x, 0, accuracy: 1)
        // 646 px scaled by 1800/1176 is 989 px, i.e. 494.5 pt tall; bands of 22.7 pt above and below.
        XCTAssertNil(fit.windowPoint(for: CGPoint(x: 450, y: 10)))
        XCTAssertNil(fit.windowPoint(for: CGPoint(x: 450, y: 530)))
        XCTAssertNotNil(fit.windowPoint(for: CGPoint(x: 450, y: 30)))
    }

    func testFillAndNativeScale() throws {
        let fill = try XCTUnwrap(mapping(.fill).windowPoint(for: CGPoint(x: 450, y: 270)))
        XCTAssertEqual(fill.x, 400, accuracy: 0.5)
        XCTAssertEqual(fill.y, 220, accuracy: 0.5)
        // Native scale draws 1 capture pixel per drawable pixel: 588 x 323 pt, centred.
        let native = mapping(.nativeScale)
        XCTAssertNil(native.windowPoint(for: CGPoint(x: 100, y: 270)))
        let left = try XCTUnwrap(native.windowPoint(for: CGPoint(x: 450 - 294 + 1, y: 270)))
        XCTAssertEqual(left.x, 800.0 / 1176 * 2, accuracy: 0.1)
        XCTAssertNil(PreviewPointMapping(viewSize: .zero, backingScale: 2, capturePixelSize: .zero,
                                         windowSize: .zero, mode: .fit).windowPoint(for: .zero))
    }

    func testScrollDeltaFollowsTheDrawnScale() {
        // Fit: 1 preview pt = 2 px = 2/1.5306 capture px = 0.889 window pt.
        let delta = mapping(.fit).windowDelta(for: CGSize(width: 0, height: 90))
        XCTAssertEqual(delta.height, 90 * 2 / (1800.0 / 1176) * 800 / 1176, accuracy: 0.01)
    }

    func testEvidenceAppliesOnlyToTheTestedAppAndOS() throws {
        let trials = [FocusState.otherWindowKey, .appInactive].map {
            InputTrial(route: .accessibility, kind: .text, condition: .parked, focus: $0, outcome: .pass, sideEffects: [])
        }
        let evidence = InputEvidence(macOS: "27.0 (26A428)", macOSMajor: 27,
                                     sources: [.init(bundleIdentifier: "com.apple.TextEdit", appVersion: "1.21",
                                                     report: "docs/input-probe/x.md", trials: trials)])
        let decoded = try JSONDecoder().decode(InputEvidence.self, from: JSONEncoder().encode(evidence))
        XCTAssertEqual(decoded, evidence)
        XCTAssertEqual(evidence.capabilities(for: "com.apple.TextEdit", appVersion: "1.21", macOSMajor: 27)
                        .verdict(.accessibility, .text, .parked), .verified)
        XCTAssertEqual(evidence.capabilities(for: "com.apple.TextEdit", appVersion: "1.21", macOSMajor: 28)
                        .verdict(.accessibility, .text, .parked), .untested)
        XCTAssertEqual(evidence.capabilities(for: "com.example.other", appVersion: "1.21", macOSMajor: 27)
                        .verdict(.accessibility, .text, .parked), .untested)
        XCTAssertEqual(evidence.capabilities(for: nil, appVersion: "1.21", macOSMajor: 27)
                        .verdict(.accessibility, .text, .parked), .untested)
    }

    func testPreviewPolicyAllowsPrivateRouteButNotAppOrDesktopSwitches() {
        func trials(_ route: InputRoute, _ kind: InputKind, _ effects: Set<InputSideEffect>) -> [InputTrial] {
            [FocusState.otherWindowKey, .appInactive].map {
                InputTrial(route: route, kind: kind, condition: .parked, focus: $0, outcome: .pass, sideEffects: effects)
            }
        }
        let capabilities = InputCapabilities(trials: trials(.windowTargetedEvent, .pointerClick, [.sourceKeyWindow])
            + trials(.accessibility, .pointerClick, [])
            + trials(.accessibility, .text, [.desktop])
            + trials(.activateAndPost, .scroll, []))
        // A real click through the exact window is preferred over a semantic press.
        XCTAssertEqual(InputPlanner.decide(.pointerClick, selectedWindowID: 4, resolution: .exact(windowID: 4),
                                           condition: .parked, capabilities: capabilities, policy: .preview),
                       .send(.windowTargetedEvent, handBackFocus: false))
        XCTAssertEqual(InputPlanner.candidates(.pointerClick, selectedWindowID: 4, resolution: .exact(windowID: 4),
                                               condition: .parked, capabilities: capabilities, policy: .preview),
                       .success([.windowTargetedEvent, .accessibility]))
        // Text that switched desktops, and a route that switches apps, stay refused.
        XCTAssertEqual(InputPlanner.decide(.text, selectedWindowID: 4, resolution: .exact(windowID: 4),
                                           condition: .parked, capabilities: capabilities, policy: .preview),
                       .refuse(.notVerified))
        XCTAssertEqual(InputPlanner.decide(.scroll, selectedWindowID: 4, resolution: .exact(windowID: 4),
                                           condition: .parked, capabilities: capabilities, policy: .preview),
                       .refuse(.notVerified))
        XCTAssertEqual(InputPlanner.candidates(.text, selectedWindowID: 4, resolution: .ambiguous, condition: .parked,
                                               capabilities: capabilities, policy: .preview),
                       .failure(.ambiguousTarget))
        XCTAssertEqual(InputPlanner.support(in: .parked, capabilities: capabilities, policy: .preview),
                       .interactive([.pointerClick]))
    }

    func testHiddenAppsStayViewOnlyWithoutHiddenEvidence() {
        let trials = [FocusState.otherWindowKey, .appInactive].map {
            InputTrial(route: .accessibility, kind: .text, condition: .visible, focus: $0,
                       outcome: .pass, sideEffects: [])
        }
        let capabilities = InputCapabilities(trials: trials)
        XCTAssertEqual(InputPlanner.support(in: .hidden, capabilities: capabilities, policy: .preview), .viewOnly)
        XCTAssertEqual(InputPlanner.decide(.text, selectedWindowID: 4, resolution: .exact(windowID: 4),
                                           condition: .hidden, capabilities: capabilities, policy: .preview),
                       .refuse(.notVerified))
    }

    func testLegacyTrialsAndPreferencesStillDecode() throws {
        let legacy = Data(#"{"route":"accessibility","kind":"text","condition":"otherSpace","focus":"appInactive","outcome":"pass","changesFocus":true}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(InputTrial.self, from: legacy).sideEffects, [.unclassifiedFocusChange])
        let noFlag = Data(#"{"route":"accessibility","kind":"text","condition":"parked","focus":"appInactive","outcome":"pass"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(InputTrial.self, from: noFlag).sideEffects, [])
        // Settings saved before the interactive option keep every choice.
        let saved = Data(#"{"trigger":"notchClick","openBehavior":"direct","dismissBehavior":"manual","contentMode":"fit","sizePreset":"wide","selectedBundleIdentifier":"com.apple.TextEdit"}"#.utf8)
        let preferences = try JSONDecoder().decode(DropyPreferences.self, from: saved)
        XCTAssertEqual(preferences.sizePreset, .wide)
        XCTAssertEqual(preferences.selectedBundleIdentifier, "com.apple.TextEdit")
        XCTAssertFalse(preferences.interactivePreview)
        var enabled = preferences
        enabled.interactivePreview = true
        XCTAssertEqual(try JSONDecoder().decode(DropyPreferences.self, from: JSONEncoder().encode(enabled)), enabled)
    }

    func testLabelsSayWhatIsVerifiedAndWhyInputWasRefused() {
        XCTAssertEqual(InteractionLabel.text(for: .interactive([.scroll, .pointerClick]), enabled: true, trusted: true, contentMode: .fit),
                       "Interactive (beta): click, scroll")
        XCTAssertEqual(InteractionLabel.text(for: .interactive([.text]), enabled: false, trusted: true, contentMode: .fit), "View only")
        XCTAssertTrue(InteractionLabel.text(for: .viewOnly, enabled: true, trusted: false, contentMode: .fit).contains("Accessibility"))
        XCTAssertEqual(InteractionLabel.text(for: .notVerified, kind: .text), "Typing not sent: not verified for this app here")
    }
}
