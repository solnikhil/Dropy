import CoreGraphics
import Foundation
import XCTest
import DropyCore

final class SourceConcealmentTests: XCTestCase {
    /// The measured test Mac: one display, and a window AppKit clamped into the
    /// bottom-right corner, which leaves a 40 x 118 pt strip on screen.
    private let main = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    private let clamped = CGRect(x: 1670, y: 994, width: 800, height: 440)
    private var strip: CGRect { CGRect(x: 1670, y: 994, width: 40, height: 118) }

    private func containment(mode: PlacementMode? = .parked, bounds: CGRect? = nil,
                             isOnScreen: Bool = true, covered: [CGRect] = []) -> SourceContainment {
        SourceContainment(mode: mode, bounds: bounds ?? clamped, isOnScreen: isOnScreen,
                          displays: [main], covered: covered)
    }

    func testAWindowDropyDidNotPlaceIsNeverCalledHidden() {
        // Another app's window in front of the source is not Dropy's containment.
        XCTAssertEqual(containment(mode: nil).concealment, .visible)
        XCTAssertEqual(containment(mode: nil, bounds: CGRect(x: 5000, y: 0, width: 800, height: 440),
                                   isOnScreen: false).concealment, .visible)
    }

    func testMinimizingAndHidingAreNotAThrottledWindow() {
        // Both stop the drawing, so no frame rate can say anything about the app.
        XCTAssertEqual(containment(mode: .minimize).concealment, .notRendering)
        XCTAssertEqual(containment(mode: .hideApp).concealment, .notRendering)
        // Same for a window the window server does not list at all.
        XCTAssertEqual(SourceContainment(mode: .parked, bounds: nil, isOnScreen: false,
                                         displays: [main]).concealment, .notRendering)
        // And with no display list there is nothing to measure against, as for a restore.
        XCTAssertEqual(SourceContainment(mode: .parked, bounds: clamped, isOnScreen: true,
                                         displays: []).concealment, .notRendering)
    }

    func testParkedIsHiddenOnlyWhileTheTabsCoverTheWholeStrip() {
        // Measured 2026-09-30: parked Safari kept onscreen=1 with uncovered=0.000.
        XCTAssertEqual(containment(covered: [strip]).concealment, .hidden)
        // The sliver AppKit leaves is visible until a tab covers it: at 1.6% of the
        // window, Safari and QuickTime both stayed near 60 fps.
        XCTAssertEqual(containment().concealment, .visible)
        let short = CGRect(x: 1670, y: 994, width: 40, height: 100)
        XCTAssertEqual(containment(covered: [short]).concealment, .visible)
        // A tab over the wrong place hides nothing.
        XCTAssertEqual(containment(covered: [CGRect(x: 0, y: 0, width: 600, height: 400)]).concealment,
                       .visible)
    }

    func testAWindowMovedBeyondEveryDisplayIsHiddenWithoutATab() {
        let away = PlacementGeometry.offscreenFrame(for: CGRect(x: 80, y: 560, width: 800, height: 440),
                                                    displays: [main])
        XCTAssertEqual(PlacementGeometry.visibleArea(of: away, on: [main]), 0)
        // The window server reports such a window as off screen because of the move.
        XCTAssertEqual(containment(mode: .offscreen, bounds: away, isOnScreen: false).concealment, .hidden)
        XCTAssertEqual(containment(mode: .parked, bounds: away, isOnScreen: false).concealment, .hidden)
    }

    func testAWindowMinimizedAfterParkingOnADisplayIsNotCalledSlowed() {
        // The tabs still cover the strip, but the window server no longer composites the
        // window: it is minimized or its app was hidden, so it is not being drawn. This
        // reading depends on the frame still lying over a display, where being
        // composited is a fact Dropy can read; see the off-display case below.
        XCTAssertEqual(containment(isOnScreen: false, covered: [strip]).concealment, .notRendering)
        XCTAssertEqual(containment(isOnScreen: false).concealment, .notRendering)
    }

    func testOffEveryDisplayAMinimizedWindowCannotBeToldFromTheMoveAndIsStillCalledHidden() {
        // The limit of what the window server can be asked. Moved beyond every display,
        // a window is reported off screen because of the move; minimizing it, or hiding
        // its app, reports exactly the same thing, so `isOnScreen` carries no
        // information here and the frame is the only fact left. Concealment therefore
        // says `.hidden` for both, which is why "a minimized window is never called
        // slowed" holds only for a window whose frame is still over a display.
        //
        // What keeps the wrong claim off the screen is the rate itself: a window nobody
        // draws delivers no changed frames at all, so there is no animating baseline to
        // compare against and the monitor answers `.unknown` unless the source was
        // animating in the two seconds before it was hidden. A source minimized inside
        // that window is the residual case, and it is not device-verified.
        let away = PlacementGeometry.offscreenFrame(for: CGRect(x: 80, y: 560, width: 800, height: 440),
                                                   displays: [main])
        XCTAssertEqual(PlacementGeometry.visibleArea(of: away, on: [main]), 0)
        XCTAssertEqual(containment(mode: .parked, bounds: away, isOnScreen: false).concealment, .hidden)
        // A tab over nothing in particular changes none of it.
        XCTAssertEqual(containment(mode: .offscreen, bounds: away, isOnScreen: false,
                                   covered: [strip]).concealment, .hidden)
        // Minimizing is still `.notRendering` whenever Dropy asked for it, wherever the
        // frame is: the placement mode says the window is not being moved at all.
        XCTAssertEqual(containment(mode: .minimize, bounds: away, isOnScreen: false).concealment,
                       .notRendering)
    }

    func testOverlappingTabsAreNotCountedAsCoveringMoreThanTheyDo() {
        // Two tabs that overlap cover 110 of the strip's 118 pt. Adding their areas
        // (2 x 2400 against 4720 pt²) would wrongly conclude that nothing is visible.
        let upper = CGRect(x: 1670, y: 994, width: 40, height: 60)
        let lower = CGRect(x: 1670, y: 1044, width: 40, height: 60)
        XCTAssertEqual(PlacementGeometry.unionArea([upper, lower]), 4400, accuracy: 0.001)
        XCTAssertEqual(PlacementGeometry.uncoveredArea(of: clamped, on: [main], covered: [upper, lower]),
                       320, accuracy: 0.001)
        XCTAssertEqual(containment(covered: [upper, lower]).concealment, .visible)
        // Overlapping tabs that do cover the strip still count as hidden.
        XCTAssertEqual(containment(covered: [upper, CGRect(x: 1670, y: 1040, width: 40, height: 72)])
                        .concealment, .hidden)
    }

    func testARoundedTabIsStillHiddenButARealSliverIsNot() {
        // AppKit rounds panel frames, so a tab can fall a fraction of a point short.
        let rounded = CGRect(x: 1670, y: 994, width: 40, height: 117.98)
        XCTAssertEqual(PlacementGeometry.uncoveredArea(of: clamped, on: [main], covered: [rounded]),
                       0.8, accuracy: 0.001)
        XCTAssertEqual(containment(covered: [rounded]).concealment, .hidden)
        let sliver = CGRect(x: 1670, y: 994, width: 40, height: 117.9)
        XCTAssertEqual(PlacementGeometry.uncoveredArea(of: clamped, on: [main], covered: [sliver]),
                       4, accuracy: 0.001)
        XCTAssertEqual(containment(covered: [sliver]).concealment, .visible)
    }

    func testMirroredDisplaysDoNotCountTheSamePixelsTwice() {
        // CGGetActiveDisplayList reports mirrored displays with identical bounds.
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(PlacementGeometry.visibleArea(of: frame, on: [main, main]), 10_000, accuracy: 0.001)
        XCTAssertEqual(PlacementGeometry.visibleFraction(of: frame, on: [main, main]), 1)
        XCTAssertEqual(PlacementGeometry.uncoveredArea(of: frame, on: [main, main],
                                                       covered: [frame]), 0, accuracy: 0.001)
    }
}
