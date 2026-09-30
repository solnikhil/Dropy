import CoreGraphics
import Foundation
import XCTest
import DropyCore

final class HandOffTests: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 1_000)
    private var identity: WindowIdentity {
        WindowIdentity(processID: 42, processLaunchDate: launch, windowID: 7, bundleIdentifier: "com.example.editor")
    }
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let original = WindowPlacementState(frame: CGRect(x: 100, y: 120, width: 800, height: 600),
                                                isMinimized: false, isAppHidden: false)
    private let parked = WindowPlacementState(frame: CGRect(x: 1511, y: 120, width: 800, height: 600),
                                              isMinimized: false, isAppHidden: false)
    private func entry(confirmed: Bool? = true) -> PlacementEntry {
        PlacementEntry(identity: identity, mode: .parked, original: original, applied: parked,
                       createdAt: launch, applicationConfirmed: confirmed)
    }
    private func start(_ trigger: HandOff.Trigger = .personRequest, entry: PlacementEntry?,
                       current: WindowPlacementState?, frontmost: Int32? = 9) -> Result<HandOff.Start, HandOff.Refusal> {
        HandOff.start(trigger: trigger, entry: entry, current: current, displays: [display], frontmost: frontmost, source: 42)
    }

    func testOnlyAPersonCanStartAHandOff() {
        XCTAssertEqual(start(.automatic, entry: entry(), current: parked), .failure(.notRequestedByPerson))
    }

    func testAParkedWindowIsPutBackAndReparkedWhenUntouched() throws {
        let plan = try start(entry: entry(), current: parked).get()
        XCTAssertEqual(plan.restoreTo, original)
        XCTAssertEqual(plan.reparkMode, .parked)
        XCTAssertEqual(plan.returnFocusTo, 9)
        XCTAssertEqual(plan.label, "Typing in the real window · the preview is paused")
        // The person typed, stayed in the source app, and touched nothing else.
        let end = HandOff.end(plan, current: original, frontmost: 42, source: 42, returnAppRunning: true)
        XCTAssertEqual(end, HandOff.End(repark: .parked, activate: 9))
    }

    func testAMoveDuringTheHandOffWins() throws {
        let plan = try start(entry: entry(), current: parked).get()
        var moved = original
        moved.frame.origin.x += 40
        XCTAssertEqual(HandOff.end(plan, current: moved, frontmost: 42, source: 42, returnAppRunning: true),
                       HandOff.End(repark: nil, activate: 9))
        // A rounding difference within the tolerance is not a move.
        var rounded = original
        rounded.frame.origin.x += 1
        XCTAssertEqual(HandOff.end(plan, current: rounded, frontmost: 42, source: 42, returnAppRunning: true).repark, .parked)
        // Minimizing it is a choice too.
        var minimized = original
        minimized.isMinimized = true
        XCTAssertNil(HandOff.end(plan, current: minimized, frontmost: 42, source: 42, returnAppRunning: true).repark)
    }

    func testFocusReturnsOnlyIfThePersonIsStillInTheSourceApp() throws {
        let plan = try start(entry: entry(), current: parked).get()
        XCTAssertNil(HandOff.end(plan, current: original, frontmost: 77, source: 42, returnAppRunning: true).activate)
        XCTAssertNil(HandOff.end(plan, current: original, frontmost: 42, source: 42, returnAppRunning: false).activate)
        // Started from the source app itself: there is nothing to return to.
        let fromSource = try start(entry: entry(), current: parked, frontmost: 42).get()
        XCTAssertNil(fromSource.returnFocusTo)
        XCTAssertNil(HandOff.end(fromSource, current: original, frontmost: 42, source: 42, returnAppRunning: true).activate)
    }

    func testAWindowThePersonMovedBeforeTheHandOffIsNotMovedOrReparked() throws {
        var elsewhere = parked
        elsewhere.frame.origin = CGPoint(x: 300, y: 300)
        let plan = try start(entry: entry(), current: elsewhere).get()
        XCTAssertNil(plan.restoreTo)
        XCTAssertNil(plan.reparkMode)
        XCTAssertEqual(HandOff.end(plan, current: elsewhere, frontmost: 42, source: 42, returnAppRunning: true).repark, nil)
    }

    func testAMinimizedOrHiddenWindowIsShownInPlace() throws {
        var minimized = original
        minimized.isMinimized = true
        let plan = try start(entry: nil, current: minimized).get()
        XCTAssertEqual(plan.restoreTo, original)
        XCTAssertNil(plan.reparkMode)
        // An unplaced, visible window needs nothing done.
        XCTAssertNil(try start(entry: nil, current: original).get().restoreTo)
        // A minimize placement is undone to a visible window and re-applied afterwards.
        var minimizedByDropy = original
        minimizedByDropy.isMinimized = true
        let placed = PlacementEntry(identity: identity, mode: .minimize, original: original, applied: minimizedByDropy,
                                    createdAt: launch, applicationConfirmed: true)
        let undone = try start(entry: placed, current: minimizedByDropy).get()
        XCTAssertEqual(undone.restoreTo, original)
        XCTAssertEqual(undone.reparkMode, .minimize)
    }

    func testAGoneWindowOrAnUnresolvedPlacementRefuses() {
        XCTAssertEqual(start(entry: entry(), current: nil), .failure(.sourceGone))
        XCTAssertEqual(start(entry: nil, current: nil), .failure(.sourceGone))
        // A crash may have interrupted the move: recovery must resolve it first.
        var clamped = parked
        clamped.frame.origin.x = 1472
        XCTAssertEqual(start(entry: entry(confirmed: false), current: clamped), .failure(.placementUnresolved))
    }

    func testAnOriginalOnADisconnectedDisplayIsBroughtOntoTheMainOne() throws {
        let offDisplay = WindowPlacementState(frame: CGRect(x: 3000, y: 100, width: 800, height: 600),
                                              isMinimized: false, isAppHidden: false)
        let placed = PlacementEntry(identity: identity, mode: .parked, original: offDisplay, applied: parked,
                                    createdAt: launch, applicationConfirmed: true)
        let plan = try start(entry: placed, current: parked).get()
        let restored = try XCTUnwrap(plan.restoreTo)
        XCTAssertTrue(display.contains(restored.frame))
        XCTAssertEqual(plan.expected, restored)
    }
}
