import XCTest
import CoreGraphics
import Foundation
import DropyCore

final class WorkspaceLayoutTests: XCTestCase {
    private let screen = CGSize(width: 1710, height: 1112)
    private let notch = CGSize(width: 208, height: 37.5)
    func testSmallSourceLivesAtNativeSizeBelowHousing() {
        let layout = WorkspaceLayout.make(source: CGSize(width: 310, height: 200), screen: screen, notch: notch, expanded: false)
        XCTAssertEqual(layout.preview.size, CGSize(width: 310, height: 200))
        XCTAssertEqual(layout.size.height, 200 + 37.5 + 8)
        XCTAssertEqual(layout.preview.maxY, layout.size.height - notch.height)
    }
    func testWhatsAppUsesItsMeasuredWindowSize() {
        // Read from window 6663 on 2026-10-03; this is a regression fixture,
        // never a production app-size preset.
        let source = CGSize(width: 1200, height: 800)
        let layout = WorkspaceLayout.make(source: source, screen: screen, notch: notch, expanded: false)
        XCTAssertEqual(layout.preview.size, source)
        XCTAssertEqual(layout.size, CGSize(width: 1216, height: 845.5))
    }
    func testMeasuredWindowFitsCompactBudget() {
        let layout = WorkspaceLayout.make(source: CGSize(width: 1200, height: 800), screen: screen,
            notch: notch, expanded: false, maximumSize: CGSize(width: 600, height: 360))
        XCTAssertEqual(layout.size.height, 360)
        XCTAssertEqual(layout.preview.height, 314.5)
        XCTAssertEqual(layout.preview.width / layout.preview.height, 1.5, accuracy: 0.001)
        XCTAssertTrue(layout.size.width <= 600)
        let expanded = WorkspaceLayout.make(source: CGSize(width: 1200, height: 800), screen: screen,
            notch: notch, expanded: true, maximumSize: CGSize(width: 600, height: 360))
        XCTAssertTrue(expanded.size.height > layout.size.height)
    }
    func testLargeSourceFitsWithoutLosingAspectRatio() {
        let source = CGSize(width: 2400, height: 1600)
        let layout = WorkspaceLayout.make(source: source, screen: screen, notch: notch, expanded: false)
        XCTAssertTrue(layout.size.width <= screen.width)
        XCTAssertTrue(layout.size.height <= screen.height)
        XCTAssertEqual(layout.preview.width / layout.preview.height, source.width / source.height, accuracy: 0.001)
    }
    func testExpandedAndNativeUseSameSourceAspectRatio() {
        let source = CGSize(width: 310, height: 200)
        let native = WorkspaceLayout.make(source: source, screen: screen, notch: notch, expanded: false)
        let expanded = WorkspaceLayout.make(source: source, screen: screen, notch: notch, expanded: true)
        XCTAssertTrue(expanded.preview.height > native.preview.height)
        XCTAssertEqual(expanded.preview.width / expanded.preview.height, 1.55, accuracy: 0.001)
    }
    func testNarrowSourceReservesUsableControlsBesideHousing() {
        let layout = WorkspaceLayout.make(source: CGSize(width: 160, height: 300), screen: screen, notch: notch, expanded: false)
        XCTAssertTrue(layout.size.width >= notch.width + 80)
        XCTAssertEqual(layout.preview.height, 300)
    }
    func testTrueSizeKeepsWindowsLargerThanEveryPreset() throws {
        let source = CGSize(width: 1300, height: 760)
        let layout = WorkspaceLayout.make(source: source, screen: screen, notch: notch, expanded: false,
                                          maximumSize: SizePreset.trueSize.maximumSize)
        XCTAssertEqual(layout.preview.size, source)
        XCTAssertEqual(SizePreset.trueSize.title, "True size")
        let saved = try JSONEncoder().encode(SizePreset.trueSize)
        XCTAssertEqual(try JSONDecoder().decode(SizePreset.self, from: saved), .trueSize)
    }
    func testNewSettingsMigrateAndPersist() throws {
        let old = try JSONDecoder().decode(DropyPreferences.self, from: Data(#"{"trigger":"notchClick","contentMode":"fill"}"#.utf8))
        XCTAssertFalse(old.restrictNotchCrossing)
        XCTAssertTrue(old.automaticWindowSize)
        XCTAssertEqual(old.contentMode, .fill)
        var preferences = old
        preferences.restrictNotchCrossing = true
        preferences.automaticWindowSize = false
        XCTAssertEqual(try JSONDecoder().decode(DropyPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }
}
