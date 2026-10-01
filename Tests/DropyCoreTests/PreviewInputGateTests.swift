import CoreGraphics
import Foundation
import XCTest
import DropyCore

final class PreviewInputGateTests: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 1_000)
    private var a: WindowIdentity { WindowIdentity(processID: 10, processLaunchDate: launch, windowID: 1, bundleIdentifier: "x") }
    private var b: WindowIdentity { WindowIdentity(processID: 10, processLaunchDate: launch, windowID: 2, bundleIdentifier: "x") }
    private let size = CGSize(width: 800, height: 440)
    private let pixels = CGSize(width: 1176, height: 646)

    private func frame(window: UInt32 = 1, pixels: CGSize? = nil, windowSize: CGSize? = nil,
                       tagged: Bool = true) -> PresentedFrame {
        let drawn = pixels ?? self.pixels
        return PresentedFrame(pixelSize: drawn, geometry: tagged
            ? CaptureGeometry(windowID: window, windowSize: windowSize ?? size, pixelSize: self.pixels) : nil)
    }

    func testCurrentFrameOfTheSelectedWindowPasses() {
        XCTAssertEqual(PreviewInputGate.check(handler: a, selected: a, frame: frame(), sourceWindowSize: size, contentMode: .fit), .success(size))
        // Accessibility and the window server may round differently.
        XCTAssertEqual(PreviewInputGate.check(handler: a, selected: a, frame: frame(),
                                              sourceWindowSize: CGSize(width: 800.5, height: 439.5), contentMode: .fit), .success(size))
    }

    func testRapidSwitchingRefusesAnOldHandlerOrALateFrame() {
        // A handler installed for A must not act once B is selected.
        XCTAssertEqual(PreviewInputGate.check(handler: a, selected: b, frame: frame(), sourceWindowSize: size, contentMode: .fit),
                       .failure(.sourceChanged))
        XCTAssertEqual(PreviewInputGate.check(handler: a, selected: nil, frame: frame(), sourceWindowSize: size, contentMode: .fit),
                       .failure(.sourceChanged))
        // B's handler while A's last frame is still drawn.
        XCTAssertEqual(PreviewInputGate.check(handler: b, selected: b, frame: frame(window: 1), sourceWindowSize: size, contentMode: .fit),
                       .failure(.frameFromOtherWindow))
        // Relaunch: same window ID, other process or launch date is a different identity.
        let relaunched = WindowIdentity(processID: 11, processLaunchDate: launch.addingTimeInterval(5), windowID: 1,
                                        bundleIdentifier: "x")
        XCTAssertEqual(PreviewInputGate.check(handler: a, selected: relaunched, frame: frame(), sourceWindowSize: size, contentMode: .fit),
                       .failure(.sourceChanged))
    }

    func testNoFrameIsRefused() {
        XCTAssertEqual(PreviewInputGate.check(handler: a, selected: a, frame: nil, sourceWindowSize: size, contentMode: .fit), .failure(.noFrame))
        XCTAssertEqual(PreviewInputGate.check(handler: a, selected: a, frame: frame(pixels: .zero), sourceWindowSize: size, contentMode: .fit),
                       .failure(.noFrame))
    }

    func testResizeUntilTheStreamCatchesUpIsRefused() {
        let resized = CGSize(width: 900, height: 440)
        // The window grew; the frame still shows the old configuration.
        XCTAssertEqual(PreviewInputGate.check(handler: a, selected: a, frame: frame(), sourceWindowSize: resized, contentMode: .fit),
                       .failure(.geometryChanging))
        // Reconfigured, but the drawn buffer predates the new output size.
        XCTAssertEqual(PreviewInputGate.check(handler: a, selected: a,
                                              frame: frame(pixels: CGSize(width: 1100, height: 646)), sourceWindowSize: size, contentMode: .fit),
                       .failure(.geometryChanging))
        // A frame without a geometry tag is never trusted.
        XCTAssertEqual(PreviewInputGate.check(handler: a, selected: a, frame: frame(tagged: false), sourceWindowSize: size, contentMode: .fit),
                       .failure(.geometryChanging))
        XCTAssertEqual(PreviewInputGate.check(handler: a, selected: a, frame: frame(), sourceWindowSize: nil, contentMode: .fit),
                       .failure(.geometryChanging))
    }
    func testMeasuredGeometryRejectsOldFramesAfterProportionalResize() {
        let pixels = CGSize(width: 1040, height: 824)
        let old = CaptureGeometry.measured(windowID: 1, pixelSize: pixels,
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 412), contentScale: 1, scaleFactor: 2)
        let resized = CGSize(width: 1040, height: 824)
        XCTAssertEqual(old?.windowSize, CGSize(width: 520, height: 412))
        XCTAssertEqual(PreviewInputGate.check(handler: a, selected: a,
            frame: PresentedFrame(pixelSize: pixels, geometry: old), sourceWindowSize: resized, contentMode: .fit), .failure(.geometryChanging))
        let current = CaptureGeometry.measured(windowID: 1, pixelSize: pixels,
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 412), contentScale: 0.5, scaleFactor: 2)
        XCTAssertEqual(current?.windowSize, resized)
        XCTAssertNil(CaptureGeometry.measured(windowID: 1, pixelSize: pixels,
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), contentScale: 1, scaleFactor: 2))
        XCTAssertNil(CaptureGeometry.measured(windowID: 1, pixelSize: pixels,
            contentRect: nil, contentScale: 1, scaleFactor: 2))
    }

}
