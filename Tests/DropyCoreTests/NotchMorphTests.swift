import XCTest
import CoreGraphics
import DropyCore

final class NotchMorphTests: XCTestCase {
    /// The wide overlay in its window, laid out as the overlay controller does.
    private let size = CGSize(width: 1200, height: 700)
    private var margin: CGFloat { NotchMorph.overshootMargin(for: size) }
    private var canvas: CGSize { CGSize(width: size.width + 2 * margin, height: size.height + margin) }
    private var notch: NotchShape { NotchShape.notch(size: CGSize(width: 208, height: 37.5), in: canvas) }
    private var open: NotchShape { NotchShape.open(body: CGRect(origin: CGPoint(x: margin, y: margin), size: size)) }

    func testSpringsStartAtRestAndSettleOnTarget() {
        for curve in [NotchMorph.open.width, NotchMorph.open.height, NotchMorph.close.width, NotchMorph.close.height] {
            XCTAssertEqual(curve.value(at: 0), 0)
            XCTAssertEqual(curve.value(at: curve.duration), 1, accuracy: 0.003)
        }
        // Opening overshoots a little; closing never does, so it cannot poke out of the notch.
        let peak = stride(from: 0.0, to: 1, by: 0.005).map(NotchMorph.open.height.value).max() ?? 0
        XCTAssertTrue(peak > 1.005)
        XCTAssertTrue(peak < 1.03)
        XCTAssertTrue((stride(from: 0.0, to: 1, by: 0.005).map(NotchMorph.close.width.value).max() ?? 2) <= 1)
    }

    func testFramesStartAtTheNotchEndOpenAndStayInsideTheWindow() {
        let frames = NotchMorph.frames(from: notch, to: open, motion: NotchMorph.open)
        XCTAssertEqual(frames.shapes.first, notch)
        XCTAssertEqual(frames.shapes.last, open)
        XCTAssertEqual(frames.keyTimes.first, 0)
        XCTAssertEqual(frames.keyTimes.last, 1)
        XCTAssertTrue(frames.duration < 1)
        let window = CGRect(origin: .zero, size: canvas)
        for shape in frames.shapes {
            XCTAssertEqual(shape.body.maxY, canvas.height, accuracy: 0.001, "hangs from the top edge")
            XCTAssertTrue(window.contains(shape.fillPath.boundingBoxOfPath.insetBy(dx: 0.5, dy: 0.5)),
                          "overshoot stays inside the window")
        }
    }

    func testClosingCollapsesHeightBeforeWidth() {
        let frames = NotchMorph.frames(from: open, to: notch, motion: NotchMorph.close)
        let early = frames.shapes[frames.shapes.count / 6]
        let heightDone = (open.body.height - early.body.height) / (open.body.height - notch.body.height)
        let widthDone = (open.body.width - early.body.width) / (open.body.width - notch.body.width)
        XCTAssertTrue(heightDone > widthDone)
    }

    func testAnInterruptedMorphStartsFromWhereTheOutlineIs() {
        let frames = NotchMorph.frames(from: notch, to: open, motion: NotchMorph.open)
        XCTAssertEqual(NotchMorph.shape(in: frames.shapes, duration: frames.duration, at: 0), notch)
        XCTAssertEqual(NotchMorph.shape(in: frames.shapes, duration: frames.duration, at: frames.duration + 1), open)
        let middle = NotchMorph.shape(in: frames.shapes, duration: frames.duration, at: frames.duration / 4)
        XCTAssertNotNil(middle)
        XCTAssertTrue((middle?.body.width ?? 0) > notch.body.width && (middle?.body.width ?? .infinity) < open.body.width * 1.03)
    }

    func testResizingBetweenOpenSizesBarelyOvershoots() {
        let peak = stride(from: 0.0, to: 1.5, by: 0.005).map(NotchMorph.resize.height.value).max() ?? 0
        XCTAssertTrue(peak < 1.005)
        XCTAssertEqual(open.offsetBy(dx: 5, dy: -3).body, open.body.offsetBy(dx: 5, dy: -3))
    }
}
