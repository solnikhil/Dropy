import XCTest
import DropyCore

final class SourceConditionRuleTests: XCTestCase {
    func testCoverageAndOwnOverlayExclusion() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let own = WindowAboveSource(ownerProcessID: 1, bounds: bounds, alpha: 1)
        let other = WindowAboveSource(ownerProcessID: 2, bounds: bounds, alpha: 1)
        XCTAssertEqual(SourceCoverageRule.coverage(at: .zero, windowsAbove: nil, ownProcessID: 1), .unknown)
        XCTAssertEqual(SourceCoverageRule.coverage(at: .zero, windowsAbove: [own], ownProcessID: 1), .uncovered)
        XCTAssertEqual(SourceCoverageRule.coverage(at: .zero, windowsAbove: [own, other], ownProcessID: 1), .covered)
    }

    func testUnknownObservationsNeverBecomeVisibleEvidence() {
        var state = SourceObservation(applicationIsHidden: false, isMinimized: false, windowSpaces: [1],
                                      activeSpaces: [1], parkedByDropy: false, visibleFraction: 1, coverage: .covered)
        XCTAssertEqual(SourceConditionRule.condition(state), .covered)
        state.coverage = .unknown
        XCTAssertNil(SourceConditionRule.condition(state))
        state.coverage = .uncovered
        state.activeSpaces = nil
        XCTAssertNil(SourceConditionRule.condition(state))
        state.activeSpaces = [2]
        XCTAssertEqual(SourceConditionRule.condition(state), .otherSpace)
        state.applicationIsHidden = true
        XCTAssertEqual(SourceConditionRule.condition(state), .hidden)
    }
}
