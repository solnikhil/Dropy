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
        HandOff.start(trigger: trigger, trusted: true, entry: entry, read: current.map { .state($0) } ?? .unreachable(.windowClosed), displays: [display], frontmost: frontmost, source: 42)
    }

    func testOnlyAPersonCanStartAHandOff() {
        XCTAssertEqual(start(.automatic, entry: entry(), current: parked), .failure(.notRequestedByPerson))
    }

    func testAParkedWindowIsPutBackAndReparkedWhenUntouched() throws {
        let plan = try start(entry: entry(), current: parked).get()
        XCTAssertEqual(plan.restoreTo, original)
        XCTAssertEqual(plan.reparkMode, .parked)
        XCTAssertEqual(plan.returnFocusTo, 9)
        XCTAssertEqual(plan.label, HandOff.label)
        // The person typed, stayed in the source app, and touched nothing else.
        let end = HandOff.end(plan, read: .state(original), frontmost: 42, source: 42, returnAppRunning: true)
        XCTAssertEqual(end, HandOff.End(repark: .parked, activate: 9))
    }

    func testAMoveDuringTheHandOffWins() throws {
        let plan = try start(entry: entry(), current: parked).get()
        var moved = original
        moved.frame.origin.x += 40
        XCTAssertEqual(HandOff.end(plan, read: .state(moved), frontmost: 42, source: 42, returnAppRunning: true),
                       HandOff.End(repark: nil, activate: 9))
        // A rounding difference within the tolerance is not a move.
        var rounded = original
        rounded.frame.origin.x += 1
        XCTAssertEqual(HandOff.end(plan, read: .state(rounded), frontmost: 42, source: 42, returnAppRunning: true).repark, .parked)
        // Minimizing it is a choice too.
        var minimized = original
        minimized.isMinimized = true
        XCTAssertNil(HandOff.end(plan, read: .state(minimized), frontmost: 42, source: 42, returnAppRunning: true).repark)
    }

    func testFocusReturnsOnlyIfThePersonIsStillInTheSourceApp() throws {
        let plan = try start(entry: entry(), current: parked).get()
        XCTAssertNil(HandOff.end(plan, read: .state(original), frontmost: 77, source: 42, returnAppRunning: true).activate)
        XCTAssertNil(HandOff.end(plan, read: .state(original), frontmost: 42, source: 42, returnAppRunning: false).activate)
        // Started from the source app itself: there is nothing to return to.
        let fromSource = try start(entry: entry(), current: parked, frontmost: 42).get()
        XCTAssertNil(fromSource.returnFocusTo)
        XCTAssertNil(HandOff.end(fromSource, read: .state(original), frontmost: 42, source: 42, returnAppRunning: true).activate)
    }

    func testAWindowThePersonMovedBeforeTheHandOffIsNotMovedOrReparked() throws {
        var elsewhere = parked
        elsewhere.frame.origin = CGPoint(x: 300, y: 300)
        let plan = try start(entry: entry(), current: elsewhere).get()
        XCTAssertNil(plan.restoreTo)
        XCTAssertNil(plan.reparkMode)
        XCTAssertEqual(HandOff.end(plan, read: .state(elsewhere), frontmost: 42, source: 42, returnAppRunning: true).repark, nil)
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

    func testAnUnfinishedHandOffMustBeRecoveredBeforeAnotherStarts() throws {
        var interrupted = entry()
        interrupted.handOff = HandOffRecord(restoredTo: original, startedAt: launch)
        XCTAssertEqual(start(entry: interrupted, current: parked), .failure(.placementUnresolved))
        // Once recovery has cleared the record, the same window can be handed over again.
        XCTAssertEqual(try start(entry: entry(), current: parked).get().reparkMode, .parked)
    }

    func testTheButtonAppearsOnlyWhereTheHandOffIsWorthItsCost() {
        // Interactive preview on, a source on screen, and typing not verified there.
        XCTAssertEqual(HandOff.offer(interactivePreview: true, trusted: true, capturing: true, typingVerified: false, active: false),
                       .start(title: HandOff.startTitle))
        // Typing already works in the preview: containment is not given up for nothing.
        XCTAssertEqual(HandOff.offer(interactivePreview: true, trusted: true, capturing: true, typingVerified: true, active: false),
                       .hidden)
        XCTAssertEqual(HandOff.offer(interactivePreview: false, trusted: true, capturing: true, typingVerified: false, active: false),
                       .hidden)
        XCTAssertEqual(HandOff.offer(interactivePreview: true, trusted: true, capturing: false, typingVerified: false, active: false),
                       .hidden)
        // A running hand-off always offers its end, and says so, whatever else changed.
        for interactive in [true, false] {
            for capturing in [true, false] {
                for verified in [true, false] {
                    XCTAssertEqual(HandOff.offer(interactivePreview: interactive, trusted: true, capturing: capturing,
                                                 typingVerified: verified, active: true),
                                   .end(title: HandOff.endTitle, label: HandOff.label))
                }
            }
        }
    }

    func testTheRecordIsWrittenOnlyForDropysOwnPlacement() throws {
        let plan = try start(entry: entry(), current: parked).get()
        let record = try XCTUnwrap(HandOff.record(plan, on: entry(), at: launch))
        XCTAssertEqual(record.handOff, HandOffRecord(restoredTo: plan.expected, startedAt: launch))
        // Everything else about the placement is left exactly as it was.
        var expected = entry()
        expected.handOff = record.handOff
        XCTAssertEqual(record, expected)
        // A window the person minimized, hid or moved themselves is not Dropy's placement:
        // inventing a record for it would authorize undoing their own choice later.
        var minimized = original
        minimized.isMinimized = true
        let unplaced = try start(entry: nil, current: minimized).get()
        XCTAssertNil(HandOff.record(unplaced, on: nil, at: launch))
    }

    func testTheRecordCarriesNothingThatCouldRepark() throws {
        // The placement to re-apply lives only in the plan held in memory. Nothing that
        // reaches the disk can re-park a window the person was typing in.
        let plan = try start(entry: entry(), current: parked).get()
        XCTAssertEqual(plan.reparkMode, .parked)
        let record = try XCTUnwrap(HandOff.record(plan, on: entry(), at: launch)?.handOff)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(record), encoding: .utf8))
        for mode in PlacementMode.allCases {
            XCTAssertFalse(encoded.contains(mode.rawValue), "\(encoded) must name no placement mode")
        }
    }

    func testPreviewInputIsRefusedWhileTheRealWindowHasIt() {
        let frame = PresentedFrame(pixelSize: CGSize(width: 1600, height: 1200),
                                   geometry: CaptureGeometry(windowID: 7, windowSize: CGSize(width: 800, height: 600),
                                                             pixelSize: CGSize(width: 1600, height: 1200)))
        let size = CGSize(width: 800, height: 600)
        XCTAssertEqual(PreviewInputGate.check(handler: identity, selected: identity, frame: frame,
                                             sourceWindowSize: size, contentMode: .fit), .success(size))
        XCTAssertEqual(PreviewInputGate.check(handler: identity, selected: identity, frame: frame,
                                             sourceWindowSize: size, contentMode: .fit, handOffActive: true),
                       .failure(.handOffActive))
        // The hand-off outranks every other reason, so no other refusal can hide it.
        XCTAssertEqual(PreviewInputGate.check(handler: identity, selected: nil, frame: nil,
                                             sourceWindowSize: nil, contentMode: .fit, handOffActive: true),
                       .failure(.handOffActive))
    }

    func testOnlyVerifiedTypingCountsAsVerifiedTyping() {
        XCTAssertTrue(InteractionSupport.interactive([.text, .scroll]).verifies(.text))
        XCTAssertFalse(InteractionSupport.interactive([.pointerClick, .scroll]).verifies(.text))
        XCTAssertFalse(InteractionSupport.viewOnly.verifies(.text))
    }
    func testTrustAndUnreadableStateCannotAuthorizeHandOff() {
        for read: SourceWindowRead in [.state(parked), .unreachable(.onOtherSpace), .failed("AX read failed")] {
            XCTAssertEqual(HandOff.start(trigger: .personRequest, trusted: false, entry: entry(), read: read,
                                        displays: [display], frontmost: 9, source: 42), .failure(.accessibilityNotTrusted))
        }
        XCTAssertEqual(HandOff.start(trigger: .personRequest, trusted: true, entry: entry(),
                                    read: .unreachable(.onOtherSpace), displays: [display], frontmost: 9, source: 42),
                       .failure(.sourceUnreadable))
        XCTAssertEqual(HandOff.offer(interactivePreview: true, trusted: false, capturing: true,
                                    typingVerified: false, active: false), .hidden)
        XCTAssertEqual(HandOff.offer(interactivePreview: false, trusted: false, capturing: false,
                                    typingVerified: false, active: true), .end(title: HandOff.endTitle, label: HandOff.label))
    }

    func testSettlementRetainsTheOnlyRecoveryRecordUntilRestoreIsObserved() {
        XCTAssertEqual(HandOff.settle(entry(), read: .state(parked)), .keepPlacementAndRecover)
        XCTAssertEqual(HandOff.settle(entry(), read: .failed("position write ignored")), .keepPlacementAndRecover)
        XCTAssertEqual(HandOff.settle(entry(), read: .unreachable(.accessibilityNotTrusted)), .keepPlacementAndRecover)
        XCTAssertEqual(HandOff.settle(entry(), read: .state(original)), .dropEntry)
        XCTAssertEqual(HandOff.settle(nil, read: .state(original)), .nothingJournaled)
    }

    func testEndDuringSuspendedStartIsDeferredAndInvalidatesOlderWork() {
        var state = HandOff.Lifecycle()
        guard case .begin(let generation) = state.requestStart() else { return XCTFail("start refused") }
        XCTAssertEqual(state.requestEnd(reason: "sourceTerminated"), .deferred)
        XCTAssertEqual(state.requestStart(), .ignore)
        XCTAssertEqual(state.phase, .starting)
        XCTAssertEqual(state.started(), "sourceTerminated")
        guard case .end = state.requestEnd(reason: "sourceTerminated") else { return XCTFail("end refused") }
        XCTAssertFalse(state.isCurrent(generation))
        XCTAssertEqual(state.phase, .idle)
    }

    func testFailedStartClearsDeferredEndWithoutActivatingTheSource() {
        var state = HandOff.Lifecycle()
        guard case .begin(let generation) = state.requestStart() else { return XCTFail("start refused") }
        XCTAssertEqual(state.requestEnd(reason: "selectionChanged"), .deferred)
        state.startFailed()
        XCTAssertNil(state.deferredEnd)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.isCurrent(generation))
        XCTAssertEqual(state.requestEnd(reason: "old end"), .ignore)
    }

}
