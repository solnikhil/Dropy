import XCTest
import CoreGraphics
import Foundation
import DropyCore

final class DockTests: XCTestCase {
    // A 14-inch MacBook Pro: 1512 × 982 points, 32 pt notch and menu bar.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let notch = CGSize(width: 200, height: 32)

    // MARK: Geometry

    func testWindowHangsDirectlyBelowTheNotchBand() {
        let clearance = DockGeometry.clearance(notch: notch, menuBarHeight: 33)
        XCTAssertEqual(clearance, 33)
        let layout = DockGeometry.layout(windowSize: CGSize(width: 900, height: 600), screen: screen,
                                         clearance: clearance, minimumBodyWidth: DockGeometry.minimumBodyWidth(notch: notch))
        XCTAssertEqual(layout.window.maxY, screen.maxY - 33)
        XCTAssertEqual(layout.window.midX, screen.midX)
        XCTAssertEqual(layout.body.maxY, screen.maxY)
        XCTAssertEqual(layout.body.minY, layout.window.minY - DockGeometry.bottomInset)
        XCTAssertEqual(layout.body.width, 900 + 2 * DockGeometry.sideInset)
        XCTAssertEqual(layout.band.height, 33)
        XCTAssertEqual(layout.windowInBody.origin, CGPoint(x: DockGeometry.sideInset, y: DockGeometry.bottomInset))
    }

    func testNarrowWindowStillGetsRoomForTheControls() {
        let minimum = DockGeometry.minimumBodyWidth(notch: notch)
        let layout = DockGeometry.layout(windowSize: CGSize(width: 200, height: 300), screen: screen,
                                         clearance: 32, minimumBodyWidth: minimum)
        XCTAssertEqual(layout.body.width, minimum)
        XCTAssertEqual(layout.body.midX, layout.window.midX, accuracy: 0.5)
    }

    func testLayoutFollowsWhereTheWindowReallyWent() {
        // The app refused the size and macOS nudged it 4 pt lower.
        let actual = CGRect(x: 300, y: 300, width: 1000, height: 646)
        let layout = DockGeometry.layout(around: actual, screen: screen, minimumBodyWidth: 300)
        XCTAssertEqual(layout.window, actual)
        XCTAssertEqual(layout.body, CGRect(x: 292, y: 292, width: 1016, height: 690))
        XCTAssertEqual(layout.band.minY, actual.maxY)
    }

    func testPresetSizesBecomeWindowSizes() {
        let current = CGSize(width: 1300, height: 900)
        let compact = DockGeometry.windowSize(preset: .compact, adaptsToWindow: false, current: current,
                                              screen: screen, clearance: 32)
        XCTAssertEqual(compact, CGSize(width: 600 - 16, height: 360 - 32 - 8))
        let small = CGSize(width: 400, height: 250)
        XCTAssertEqual(DockGeometry.windowSize(preset: .medium, adaptsToWindow: true, current: small,
                                               screen: screen, clearance: 32), small)
        XCTAssertEqual(DockGeometry.windowSize(preset: .medium, adaptsToWindow: false, current: small,
                                               screen: screen, clearance: 32), CGSize(width: 884, height: 500))
    }

    func testNativeSizeKeepsTheWindowUnlessTheScreenIsTooSmall() {
        XCTAssertEqual(DockGeometry.windowSize(preset: .nativeSize, adaptsToWindow: true,
                                               current: CGSize(width: 800, height: 500), screen: screen, clearance: 32),
                       CGSize(width: 800, height: 500))
        let huge = DockGeometry.windowSize(preset: .nativeSize, adaptsToWindow: true,
                                           current: CGSize(width: 3000, height: 2000), screen: screen, clearance: 32)
        XCTAssertEqual(huge, CGSize(width: 1512 - 32 - 16, height: 982 - 16 - 32 - 8))
    }

    func testGlobalRectFlipsAgainstTheMainDisplay() {
        let rect = CGRect(x: 10, y: 100, width: 300, height: 200)
        XCTAssertEqual(DockGeometry.globalRect(fromAppKit: rect, mainDisplayHeight: 982),
                       CGRect(x: 10, y: 682, width: 300, height: 200))
    }

    // MARK: Clicks

    private let own: Int32 = 1, source: Int32 = 2, other: Int32 = 3
    private let body = CGRect(x: 300, y: 0, width: 916, height: 650)

    private func window(_ pid: Int32, _ bounds: CGRect, layer: Int = 0, bundle: String? = nil) -> DockPolicy.WindowAtPoint {
        DockPolicy.WindowAtPoint(processID: pid, bounds: bounds, layer: layer, bundleIdentifier: bundle)
    }

    func testClicksOnTheAppAndItsMenusStayInside() {
        let menu = window(source, CGRect(x: 1200, y: 100, width: 200, height: 300), layer: 101)
        XCTAssertTrue(DockPolicy.clickIsInside(point: CGPoint(x: 1300, y: 200), body: body, windows: [menu],
                                               ownProcessID: own, sourceProcessID: source))
        // A click in the overlay is inside even though Dropy's own panel is in front.
        let panel = window(own, body, layer: 25)
        XCTAssertTrue(DockPolicy.clickIsInside(point: CGPoint(x: 500, y: 300), body: body, windows: [panel],
                                               ownProcessID: own, sourceProcessID: source))
        let menuBar = window(0, CGRect(x: 0, y: 0, width: 1512, height: 33), layer: DockPolicy.menuBarLayer)
        XCTAssertTrue(DockPolicy.clickIsInside(point: CGPoint(x: 100, y: 10), body: body, windows: [menuBar],
                                               ownProcessID: own, sourceProcessID: source))
        let savePanel = window(9, CGRect(x: 0, y: 700, width: 600, height: 200),
                               bundle: "com.apple.appkit.xpc.openAndSavePanelService")
        XCTAssertTrue(DockPolicy.clickIsInside(point: CGPoint(x: 50, y: 750), body: body, windows: [savePanel],
                                               ownProcessID: own, sourceProcessID: source))
    }

    func testClicksElsewhereAreOutside() {
        let otherApp = window(other, CGRect(x: 0, y: 700, width: 600, height: 200))
        XCTAssertFalse(DockPolicy.clickIsInside(point: CGPoint(x: 50, y: 750), body: body, windows: [otherApp],
                                                ownProcessID: own, sourceProcessID: source))
        XCTAssertFalse(DockPolicy.clickIsInside(point: CGPoint(x: 50, y: 750), body: body, windows: [],
                                                ownProcessID: own, sourceProcessID: source), "the bare desktop")
        // Another app's menu-bar extra sits in the status layer, not the menu bar's.
        let extra = window(other, CGRect(x: 1400, y: 0, width: 30, height: 33), layer: 25)
        XCTAssertFalse(DockPolicy.clickIsInside(point: CGPoint(x: 1410, y: 10), body: body, windows: [extra],
                                                ownProcessID: own, sourceProcessID: source))
    }

    // MARK: Switching apps

    func testSwitchingToAnotherAppCloses() {
        XCTAssertTrue(DockPolicy.activationCloses(processID: other, bundleIdentifier: "com.apple.Safari",
                                                  sourceProcessID: source, ownProcessID: own))
        XCTAssertFalse(DockPolicy.activationCloses(processID: source, bundleIdentifier: nil,
                                                   sourceProcessID: source, ownProcessID: own))
        XCTAssertFalse(DockPolicy.activationCloses(processID: own, bundleIdentifier: nil,
                                                   sourceProcessID: source, ownProcessID: own))
        XCTAssertFalse(DockPolicy.activationCloses(processID: other, bundleIdentifier: "com.apple.inputmethod.Kotoeri",
                                                   sourceProcessID: source, ownProcessID: own))
    }

    // MARK: Changes by the person

    private let docked = CGRect(x: 306, y: 33, width: 900, height: 600)

    func testOwnPlacementIsUnchanged() {
        XCTAssertEqual(DockPolicy.change(expected: docked, observed: docked.offsetBy(dx: 1, dy: 0), isFullScreen: false),
                       .unchanged)
    }

    func testResizeKeepsTheWindowDocked() {
        var wider = docked
        wider.size.width += 120
        XCTAssertEqual(DockPolicy.change(expected: docked, observed: wider, isFullScreen: false), .resizedInPlace)
        var fromLeft = docked
        fromLeft.origin.x -= 80
        fromLeft.size.width += 80
        XCTAssertEqual(DockPolicy.change(expected: docked, observed: fromLeft, isFullScreen: false), .resizedInPlace)
    }

    func testDraggingAwayOrFullScreenDetaches() {
        XCTAssertEqual(DockPolicy.change(expected: docked, observed: docked.offsetBy(dx: 40, dy: 200), isFullScreen: false),
                       .detached)
        XCTAssertEqual(DockPolicy.change(expected: docked, observed: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         isFullScreen: true), .detached)
    }

    // MARK: Restore

    func testRestoringADockedWindowPutsBackItsSize() {
        let identity = WindowIdentity(processID: 2, processLaunchDate: Date(timeIntervalSince1970: 5), windowID: 9,
                                      bundleIdentifier: "x")
        let original = WindowPlacementState(frame: CGRect(x: 80, y: 120, width: 1300, height: 900),
                                            isMinimized: false, isAppHidden: false)
        let placed = WindowPlacementState(frame: docked, isMinimized: false, isAppHidden: false)
        let entry = PlacementEntry(identity: identity, mode: .docked, original: original, applied: placed,
                                   createdAt: Date(), applicationConfirmed: true)
        let plan = RestorePlan.make(for: entry, read: .state(placed), displays: [CGRect(x: 0, y: 0, width: 1512, height: 982)])
        XCTAssertEqual(plan, .restore(.restore(original), unhide: false, unminimize: false,
                                      frame: original.frame, resize: true))
        XCTAssertTrue(PlacementMode.docked.movesWindow)
    }
}
