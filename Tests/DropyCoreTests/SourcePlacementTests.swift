import CoreGraphics
import Foundation
import XCTest
import DropyCore

final class SourcePlacementTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    private let identity = WindowIdentity(processID: 7, processLaunchDate: Date(timeIntervalSince1970: 1),
                                          windowID: 99, bundleIdentifier: "com.apple.TextEdit")

    private func entry(mode: PlacementMode = .offscreen, original: CGRect = CGRect(x: 80, y: 560, width: 800, height: 440),
                       applied: CGRect? = nil) -> PlacementEntry {
        let originalState = WindowPlacementState(frame: original, isMinimized: false, isAppHidden: false)
        let appliedFrame = applied ?? PlacementGeometry.offscreenFrame(for: original, displays: [main])
        return PlacementEntry(identity: identity, mode: mode, original: originalState,
                              applied: WindowPlacementState(frame: appliedFrame, isMinimized: false, isAppHidden: false),
                              createdAt: Date(timeIntervalSince1970: 2))
    }

    func testRestoresWhenTheWindowIsWhereDropyLeftIt() {
        let placed = entry()
        XCTAssertEqual(PlacementRestorer.decide(placed, current: placed.applied, displays: [main]),
                       .restore(placed.original))
        var nudged = placed.applied
        nudged.frame.origin.x += 1.5
        XCTAssertEqual(PlacementRestorer.decide(placed, current: nudged, displays: [main]),
                       .keepUserChange)
        var resized = placed.applied
        resized.frame.size.width += 0.5
        XCTAssertEqual(PlacementRestorer.decide(placed, current: resized, displays: [main]), .keepUserChange)
    }

    func testALaterMoveByTheUserWins() {
        let placed = entry()
        var moved = placed.applied
        moved.frame.origin = CGPoint(x: 300, y: 300)
        XCTAssertEqual(PlacementRestorer.decide(placed, current: moved, displays: [main]), .keepUserChange)
        let hidden = PlacementEntry(identity: identity, mode: .hideApp, original: placed.original,
                                    applied: WindowPlacementState(frame: placed.original.frame, isMinimized: false, isAppHidden: true),
                                    createdAt: placed.createdAt)
        XCTAssertEqual(PlacementRestorer.decide(hidden, current: placed.original, displays: [main]), .keepUserChange)
    }

    func testMissingWindowAndUnpluggedDisplay() {
        let placed = entry()
        XCTAssertEqual(PlacementRestorer.decide(placed, current: nil, displays: [main]), .sourceGone)
        // The window was on a second display that is now gone.
        let external = entry(original: CGRect(x: 2000, y: 100, width: 800, height: 600))
        guard case .restoreOnFallbackDisplay(let state) =
                PlacementRestorer.decide(external, current: external.applied, displays: [main]) else {
            return XCTFail("expected fallback restore")
        }
        XCTAssertEqual(state.frame.size, CGSize(width: 800, height: 600))
        XCTAssertEqual(PlacementGeometry.visibleFraction(of: state.frame, on: [main]), 1)
    }

    func testOffscreenFrameIsFullyInvisibleAndLeakIsMeasured() {
        let second = CGRect(x: 1710, y: 0, width: 1920, height: 1080)
        let frame = CGRect(x: 80, y: 560, width: 800, height: 440)
        let away = PlacementGeometry.offscreenFrame(for: frame, displays: [main, second])
        XCTAssertEqual(PlacementGeometry.visibleFraction(of: away, on: [main, second]), 0)
        let clampedByAppKit = CGRect(x: 1670, y: 560, width: 800, height: 440)
        XCTAssertEqual(PlacementGeometry.visibleFraction(of: clampedByAppKit, on: [main]), 0.05, accuracy: 0.0001)
    }

    func testUnconfirmedClampedMoveRetainsRecoveryRecord() {
        var prepared = entry()
        prepared.applicationConfirmed = false
        var clamped = prepared.applied
        clamped.frame.origin = CGPoint(x: 1670, y: 994)
        XCTAssertEqual(PlacementRestorer.decide(prepared, current: clamped, displays: [main]), .pending)
        XCTAssertEqual(PlacementRestorer.decide(prepared, current: prepared.original, displays: [main]), .keepUserChange)
        XCTAssertEqual(PlacementRestorer.decide(prepared, current: prepared.applied, displays: [main]), .restore(prepared.original))
    }

    func testJournalEntryRoundTrips() throws {
        let placed = entry(mode: .minimize)
        let decoded = try JSONDecoder().decode(PlacementEntry.self, from: JSONEncoder().encode(placed))
        XCTAssertEqual(decoded, placed)
    }
}
