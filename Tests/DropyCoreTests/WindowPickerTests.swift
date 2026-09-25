import XCTest
import CoreGraphics
import DropyCore

final class WindowPickerTests: XCTestCase {
    private func window(_ pid: Int32, _ id: UInt32, _ app: String, _ title: String,
                        layer: Int = 0, size: CGSize = CGSize(width: 800, height: 600),
                        onScreen: Bool = true) -> WindowSummary {
        WindowSummary(processID: pid, windowID: id, applicationName: app, title: title,
                      layer: layer, size: size, isOnScreen: onScreen)
    }

    func testSameTitleWindowsGetDistinctLabelsInCreationOrder() {
        let entries = WindowPicker.entries(from: [
            window(10, 1959, "Safari", "about:blank"),
            window(10, 1953, "Safari", "about:blank"),
        ])
        XCTAssertEqual(entries.map(\.windowID), [1953, 1959])
        XCTAssertEqual(entries.map(\.label),
                       ["Safari — about:blank (1 of 2)", "Safari — about:blank (2 of 2)"])
    }

    func testFloatingLayerPanelsAreExcluded() {
        let entries = WindowPicker.entries(from: [
            window(20, 984, "ChatGPT", "ChatGPT"),
            window(20, 992, "ChatGPT", "ChatGPT", layer: 3,
                   size: CGSize(width: 1128, height: 2117), onScreen: false),
        ])
        XCTAssertEqual(entries.map(\.label), ["ChatGPT — ChatGPT"])
    }

    func testOffScreenUntitledHelperIsNotOfferedAsFallback() {
        XCTAssertTrue(WindowPicker.entries(from: [
            window(30, 1856, "TextEdit", "", size: CGSize(width: 500, height: 500), onScreen: false),
        ]).isEmpty)
        let entries = WindowPicker.entries(from: [
            window(31, 5, "Player", "", size: CGSize(width: 400, height: 300)),
            window(31, 6, "Player", "", size: CGSize(width: 900, height: 600)),
        ])
        XCTAssertEqual(entries.map(\.windowID), [6])
    }

    func testMinimizedTitledWindowStaysSelectableAndIsMarked() {
        let entries = WindowPicker.entries(from: [
            window(40, 1899, "TextEdit", "docA.txt", onScreen: false),
            window(40, 1900, "TextEdit", "docB.txt"),
        ])
        XCTAssertEqual(entries.map(\.label),
                       ["TextEdit — docA.txt · not visible", "TextEdit — docB.txt"])
    }

    func testTinyWindowsAreExcluded() {
        XCTAssertTrue(WindowPicker.entries(from: [
            window(50, 7, "Tool", "Palette", size: CGSize(width: 720, height: 84)),
        ]).isEmpty)
    }
}
