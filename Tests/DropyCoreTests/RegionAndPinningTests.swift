import CoreGraphics
import Foundation
import XCTest
import DropyCore

final class RegionAndPinningTests: XCTestCase {
    func testNormalizedRegionRejectsMalformedAndResizesInSourceCoordinates() throws {
        XCTAssertNil(NormalizedRegion(x: 0, y: 0, width: 0.001, height: 0.5))
        XCTAssertNil(NormalizedRegion(x: 0.9, y: 0, width: 0.5, height: 0.5))
        XCTAssertNil(NormalizedRegion(x: .infinity, y: 0, width: 0.5, height: 0.5))
        let region = try XCTUnwrap(NormalizedRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(region.sourceRect(inWindowOfSize: CGSize(width: 800, height: 600)),
                       CGRect(x: 200, y: 150, width: 400, height: 300))
        XCTAssertEqual(region.sourceRect(inWindowOfSize: CGSize(width: 1600, height: 1200)),
                       CGRect(x: 400, y: 300, width: 800, height: 600))
    }

    func testRegionDragClipsLetterboxAndUsesSourceProportions() throws {
        let region = try XCTUnwrap(RegionSelection.regionInWindow(fromDrag: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 150, y: 100), in: CGSize(width: 200, height: 200),
            capturePixelSize: CGSize(width: 400, height: 200), backingScale: 2))
        XCTAssertEqual(region.rect, CGRect(x: 0, y: 0, width: 0.75, height: 0.5))
        XCTAssertNil(RegionSelection.regionInWindow(fromDrag: .zero, to: CGPoint(x: 50, y: 20),
            in: CGSize(width: 200, height: 200), capturePixelSize: CGSize(width: 400, height: 200), backingScale: 2))
        XCTAssertNil(RegionSelection.imageRect(in: CGSize(width: CGFloat.infinity, height: 200),
            capturePixelSize: CGSize(width: 400, height: 200), backingScale: 2, mode: .fit))
    }

    func testRegionModeAndCroppedFramesIndependentlyRefuseInput() throws {
        let identity = WindowIdentity(processID: 42, processLaunchDate: Date(timeIntervalSince1970: 0), windowID: 7, bundleIdentifier: "editor")
        let size = CGSize(width: 800, height: 600)
        var geometry = CaptureGeometry(windowID: 7, windowSize: size, pixelSize: size)
        var frame = PresentedFrame(pixelSize: size, geometry: geometry)
        XCTAssertEqual(PreviewInputGate.check(handler: identity, selected: identity, frame: frame,
            sourceWindowSize: size, contentMode: .selectedRegion), .failure(.regionMode))
        geometry.crop = try XCTUnwrap(NormalizedRegion(x: 0, y: 0, width: 0.5, height: 0.5))
        frame.geometry = geometry
        XCTAssertEqual(PreviewInputGate.check(handler: identity, selected: identity, frame: frame,
            sourceWindowSize: size, contentMode: .fit), .failure(.regionMode))
    }

    func testPinsAreStableAndNumberKeysNeverStealLivePreviewText() {
        XCTAssertEqual(AppPinning.normalized([" a ", "", "b", "a"]), ["a", "b"])
        XCTAssertEqual(AppPinning.toggled(["a", "b"], bundleIdentifier: "a"), ["b"])
        XCTAssertEqual(AppPinning.quickSelect(characters: "1", modifiers: [], pickerShowing: true), 1)
        XCTAssertNil(AppPinning.quickSelect(characters: "1", modifiers: [], pickerShowing: false))
        XCTAssertNil(AppPinning.quickSelect(characters: "1", modifiers: .shift, pickerShowing: true))
    }

    func testOldPreferencesDecodeAndRegionsAndPinsRoundTrip() throws {
        var prefs = try JSONDecoder().decode(DropyPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(prefs.pinnedBundleIdentifiers, [])
        XCTAssertNil(prefs.selectedRegion(for: "a"))
        let region = try XCTUnwrap(NormalizedRegion(x: 0, y: 0, width: 0.5, height: 0.5))
        prefs.setSelectedRegion(region, for: "a")
        prefs.togglePin("a")
        let restored = try JSONDecoder().decode(DropyPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(restored.selectedRegion(for: "a"), region)
        XCTAssertTrue(restored.isPinned("a"))
    }
    func testRegionResolutionUsesFullWindowSurfaceWithinNativeScale() throws {
        let region = try XCTUnwrap(NormalizedRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let plan = try XCTUnwrap(RegionSelection.crop(region: region, windowSize: CGSize(width: 800, height: 600),
                            previewSize: CGSize(width: 400, height: 300), backingScale: 2))
        XCTAssertEqual(RegionSelection.fullSurface(region: region, plan: plan,
                            windowSize: CGSize(width: 800, height: 600), backingScale: 2), CGSize(width: 1600, height: 1200))
    }

}
