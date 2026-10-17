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

    func testTheOutlineCoversItsPlaceBeforeItSettles() {
        func check(_ frames: (shapes: [NotchShape], keyTimes: [Double], duration: TimeInterval), _ name: String) -> TimeInterval {
            let cover = NotchMorph.coverTime(shapes: frames.shapes, keyTimes: frames.keyTimes, duration: frames.duration)
            let target = frames.shapes.last!.body.insetBy(dx: 1, dy: 1)
            for (shape, key) in zip(frames.shapes, frames.keyTimes) where key * frames.duration >= cover {
                XCTAssertTrue(shape.body.contains(target), "\(name): uncovered at \(key * frames.duration) s")
            }
            return cover
        }
        for style in MotionStyle.allCases {
            let opening = NotchMorph.frames(from: notch, to: open, motion: style.morph.open)
            let cover = check(opening, "\(style) open")
            XCTAssertTrue(cover > 0 && cover <= opening.duration)
            // Rapid barely overshoots; the springier styles cover well before settling.
            if style != .rapid {
                XCTAssertTrue(cover < opening.duration * 0.8, "\(style) open covers at \(cover) of \(opening.duration) s")
            }
            // Shrinking to a smaller body as well as growing to a larger one.
            let smaller = NotchShape.open(body: open.body.insetBy(dx: 150, dy: 100).offsetBy(dx: 0, dy: 100))
            _ = check(NotchMorph.frames(from: open, to: smaller, motion: style.morph.resize), "\(style) shrink")
            _ = check(NotchMorph.frames(from: smaller, to: open, motion: style.morph.resize), "\(style) grow")
        }
        // A morph that never leaves its place covers it from the start.
        let still = NotchMorph.frames(from: open, to: open, motion: NotchMorph.resize)
        XCTAssertEqual(NotchMorph.coverTime(shapes: still.shapes, keyTimes: still.keyTimes, duration: still.duration), 0)
    }

    func testResizingBetweenOpenSizesBarelyOvershoots() {
        let peak = stride(from: 0.0, to: 1.5, by: 0.005).map(NotchMorph.resize.height.value).max() ?? 0
        XCTAssertTrue(peak < 1.005)
        XCTAssertEqual(open.offsetBy(dx: 5, dy: -3).body, open.body.offsetBy(dx: 5, dy: -3))
    }
}
