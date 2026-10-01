import CoreGraphics
import Foundation
import XCTest
import DropyCore

/// What the placement journal must decide about a hand-off that no longer has a Dropy:
/// a crash or forced quit while the person was typing in the real window. The window must
/// end up somewhere they can reach, and must never be parked again by anything but an
/// explicit end, whose plan lived only in the lost process's memory.
final class HandOffRecoveryTests: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 1_000)
    private var identity: WindowIdentity {
        WindowIdentity(processID: 42, processLaunchDate: launch, windowID: 7, bundleIdentifier: "com.example.editor")
    }
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let original = WindowPlacementState(frame: CGRect(x: 100, y: 120, width: 800, height: 600),
                                               isMinimized: false, isAppHidden: false)
    /// Parked: pushed beyond the display, with the strip AppKit refuses to hide left over.
    private let parked = WindowPlacementState(frame: CGRect(x: 1472, y: 120, width: 800, height: 600),
                                             isMinimized: false, isAppHidden: false)

    /// A parked window whose hand-off was interrupted; `restoredTo` is where it belongs.
    private func interrupted(mode: PlacementMode = .parked, applied: WindowPlacementState? = nil,
                            restoredTo: WindowPlacementState? = nil,
                            confirmed: Bool? = true) -> PlacementEntry {
        PlacementEntry(identity: identity, mode: mode, original: original, applied: applied ?? parked,
                       createdAt: launch, applicationConfirmed: confirmed,
                       handOff: HandOffRecord(restoredTo: restoredTo ?? original, startedAt: launch))
    }

    private func decide(_ entry: PlacementEntry, current: WindowPlacementState?,
                        displays: [CGRect]? = nil) -> RestoreDecision {
        PlacementRestorer.decide(entry, current: current, displays: displays ?? [display])
    }

    // MARK: The decision after a crash

    func testACrashWhileTheWindowWasStillParkedPutsItBack() {
        XCTAssertEqual(decide(interrupted(), current: parked), .restore(original))
        // Minimized and hidden placements are undone the same way.
        var minimized = original
        minimized.isMinimized = true
        XCTAssertEqual(decide(interrupted(mode: .minimize, applied: minimized), current: minimized),
                       .restore(original))
        var hidden = original
        hidden.isAppHidden = true
        XCTAssertEqual(decide(interrupted(mode: .hideApp, applied: hidden), current: hidden), .restore(original))
    }

    func testACrashAfterTheWindowWasBackChangesNothingAndDropsTheRecord() {
        // The ordinary case: the person was typing in a window already on screen.
        XCTAssertEqual(decide(interrupted(), current: original), .keepUserChange)
        // Rounding between Accessibility and the window server is not a move.
        var rounded = original
        rounded.frame.origin.x += 1
        XCTAssertEqual(decide(interrupted(), current: rounded), .keepUserChange)
        XCTAssertEqual(RestorePlan.make(for: interrupted(), read: .state(original), displays: [display]),
                       .settle(.keepUserChange))
    }

    func testAMoveMadeDuringTheHandOffStillWins() {
        // Their window, their position: the same rule as when a hand-off ends normally.
        var elsewhere = original
        elsewhere.frame.origin = CGPoint(x: 400, y: 400)
        XCTAssertEqual(decide(interrupted(), current: elsewhere), .keepUserChange)
        // Minimizing or hiding it during the hand-off is a choice too.
        var minimized = original
        minimized.isMinimized = true
        XCTAssertEqual(decide(interrupted(), current: minimized), .keepUserChange)
        var hidden = original
        hidden.isAppHidden = true
        XCTAssertEqual(decide(interrupted(), current: hidden), .keepUserChange)
    }

    func testAnInterruptedMoveThatLeftTheWindowOutOfReachIsFinished() {
        // The crash caught the restore part-way: the window is neither where Dropy parked
        // it nor where it belongs, and most of it is beyond every display.
        var stranded = parked
        stranded.frame.origin.x = 1300
        XCTAssertTrue(HandOff.isOutOfReach(stranded, on: [display]))
        XCTAssertEqual(decide(interrupted(), current: stranded), .restore(original))
        // Half on a display is reachable, so it counts as the person's own position.
        var halfOn = original
        halfOn.frame.origin.x = display.maxX - original.frame.width / 2
        XCTAssertFalse(HandOff.isOutOfReach(halfOn, on: [display]))
        XCTAssertEqual(decide(interrupted(), current: halfOn), .keepUserChange)
        // With no display connected nothing is called out of reach, so nothing is moved.
        XCTAssertFalse(HandOff.isOutOfReach(stranded, on: []))
        XCTAssertEqual(decide(interrupted(), current: stranded, displays: []), .keepUserChange)
    }

    func testTheWindowComesBackOntoAConnectedDisplayWhenItsOwnIsGone() throws {
        let unplugged = WindowPlacementState(frame: CGRect(x: 3000, y: 100, width: 800, height: 600),
                                            isMinimized: false, isAppHidden: false)
        let entry = interrupted(restoredTo: unplugged)
        let decision = decide(entry, current: parked)
        guard case .restoreOnFallbackDisplay(let target) = decision else {
            return XCTFail("expected a fallback display restore, got \(decision)")
        }
        XCTAssertTrue(display.contains(target.frame))
        XCTAssertEqual(target.frame.size, unplugged.frame.size)
        // The plan resizes only because the frame was clamped, and it moves the window.
        XCTAssertEqual(RestorePlan.make(for: entry, read: .state(parked), displays: [display]),
                       .restore(decision, unhide: false, unminimize: false, frame: target.frame, resize: true))
    }

    func testAGoneWindowSettlesTheRecord() {
        XCTAssertEqual(decide(interrupted(), current: nil), .sourceGone)
    }

    func testRecoveryNeverReparksWhateverTheStateWas() {
        // Every reachable state must settle or put the window back. No decision may leave
        // the window where Dropy had parked it: only an explicit end may re-park, and its
        // plan died with the process.
        var states = [original, parked]
        for offset in [-600.0, -200.0, 0.0, 40.0, 900.0] {
            var moved = original
            moved.frame.origin.x += offset
            states.append(moved)
            var minimized = moved
            minimized.isMinimized = true
            states.append(minimized)
        }
        for entry in [interrupted(), interrupted(confirmed: false), interrupted(confirmed: nil)] {
            for current in states {
                switch decide(entry, current: current) {
                case .keepUserChange:
                    XCTAssertFalse(current.approximatelyEquals(entry.applied),
                                   "a window still parked must be put back, not kept at \(current)")
                case .restore(let target), .restoreOnFallbackDisplay(let target):
                    XCTAssertFalse(target.approximatelyEquals(entry.applied), "\(target) is the parked place")
                    XCTAssertFalse(target.isMinimized || target.isAppHidden, "\(target) is out of sight")
                case .pending:
                    XCTFail("an interrupted hand-off never asks: its record says where the window belongs")
                case .sourceGone:
                    XCTFail("the window was read, so it exists")
                }
            }
        }
    }

    func testAnUnconfirmedMoveUnderAHandOffNeedsNoQuestion() {
        // Without a hand-off record an unconfirmed move is ambiguous and must be asked
        // about. The record removes the ambiguity: the person asked for the window back.
        let ambiguous = PlacementEntry(identity: identity, mode: .parked, original: original, applied: parked,
                                       createdAt: launch, applicationConfirmed: false)
        var clamped = parked
        clamped.frame.origin.x = 1400
        XCTAssertEqual(decide(ambiguous, current: clamped), .pending)
        var handedOver = ambiguous
        handedOver.handOff = HandOffRecord(restoredTo: original, startedAt: launch)
        XCTAssertEqual(decide(handedOver, current: clamped), .restore(original))
    }

    // MARK: Journals written before hand-off typing existed

    func testJournalsWrittenBeforeHandOffTypingStillDecode() throws {
        // Exactly the shape Dropy wrote before this feature: no hand-off key at all.
        // Dates are Foundation's default form, seconds since its 2001 reference date.
        let oldLaunch = Date(timeIntervalSinceReferenceDate: 1_000)
        let old = Data("""
        [{"identity":{"processID":42,"processLaunchDate":1000,"windowID":7,"bundleIdentifier":"com.example.editor"},\
        "mode":"parked","original":{"frame":[[100,120],[800,600]],"isMinimized":false,"isAppHidden":false},\
        "applied":{"frame":[[1472,120],[800,600]],"isMinimized":false,"isAppHidden":false},\
        "createdAt":2000,"applicationConfirmed":true}]
        """.utf8)
        let decoded = try JSONDecoder().decode([PlacementEntry].self, from: old)
        XCTAssertEqual(decoded.count, 1)
        let entry = try XCTUnwrap(decoded.first)
        XCTAssertEqual(entry.identity, WindowIdentity(processID: 42, processLaunchDate: oldLaunch, windowID: 7,
                                                      bundleIdentifier: "com.example.editor"))
        XCTAssertEqual(entry.mode, .parked)
        XCTAssertEqual(entry.original, original)
        XCTAssertEqual(entry.applied, parked)
        XCTAssertEqual(entry.createdAt, Date(timeIntervalSinceReferenceDate: 2_000))
        XCTAssertEqual(entry.applicationConfirmed, true)
        XCTAssertNil(entry.handOff, "an old record must not look like an interrupted hand-off")
        // And it still decides the way it always did.
        XCTAssertEqual(decide(entry, current: parked), .restore(original))
        // An older record without even the confirmation flag decodes too.
        let older = Data("""
        [{"identity":{"processID":42,"processLaunchDate":1000,"windowID":7,"bundleIdentifier":"com.example.editor"},\
        "mode":"minimize","original":{"frame":[[100,120],[800,600]],"isMinimized":false,"isAppHidden":false},\
        "applied":{"frame":[[100,120],[800,600]],"isMinimized":true,"isAppHidden":false},"createdAt":2000}]
        """.utf8)
        let legacy = try XCTUnwrap(try JSONDecoder().decode([PlacementEntry].self, from: older).first)
        XCTAssertNil(legacy.applicationConfirmed)
        XCTAssertNil(legacy.handOff)
        var minimized = original
        minimized.isMinimized = true
        XCTAssertEqual(decide(legacy, current: minimized), .restore(original))
    }

    func testAJournalThisDropyWroteLosesNoHandOffWhenReadBack() throws {
        // The file Dropy itself writes, with its hand-off member removed, is what an older
        // Dropy would have written for the same placement; both shapes must decode.
        let written = try JSONEncoder().encode([interrupted()])
        var records = try XCTUnwrap(try JSONSerialization.jsonObject(with: written) as? [[String: Any]])
        XCTAssertNotNil(records.first?["handOff"], "the record must reach the disk")
        XCTAssertEqual(try JSONDecoder().decode([PlacementEntry].self, from: written), [interrupted()])
        records[0].removeValue(forKey: "handOff")
        let older = try JSONSerialization.data(withJSONObject: records)
        XCTAssertEqual(try JSONDecoder().decode([PlacementEntry].self, from: older),
                       [PlacementEntry(identity: identity, mode: .parked, original: original, applied: parked,
                                       createdAt: launch, applicationConfirmed: true)])
    }

    func testAHandOffRecordSurvivesTheRoundTrip() throws {
        let entry = interrupted()
        let data = try JSONEncoder().encode([entry])
        XCTAssertEqual(try JSONDecoder().decode([PlacementEntry].self, from: data), [entry])
        // A record written by a newer Dropy and read back keeps deciding the same way.
        XCTAssertEqual(decide(try XCTUnwrap(try JSONDecoder().decode([PlacementEntry].self, from: data).first),
                              current: parked), .restore(original))
        // An entry with no hand-off encodes no hand-off key, so nothing older is confused.
        let plain = PlacementEntry(identity: identity, mode: .parked, original: original, applied: parked,
                                   createdAt: launch, applicationConfirmed: true)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(plain), encoding: .utf8))
        XCTAssertFalse(encoded.contains("handOff"), encoded)
    }
}
