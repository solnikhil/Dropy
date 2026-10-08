import XCTest
import CoreGraphics
import Foundation
import DropyCore

final class MotionCurveTests: XCTestCase {
    private func keys(_ points: (Double, Double, MotionEase)...) -> [MotionKeyframe] {
        points.map { MotionKeyframe(time: $0.0, value: $0.1, ease: $0.2) }
    }

    func testKeyframesPassThroughEveryKeyAndHoldAtTheEnds() {
        let curve = MotionCurve.keyframes(keys((0.05, 0, .smooth), (0.2, 1.1, .easeOut), (0.3, 0.97, .smooth),
                                               (0.4, 1, .linear)))
        XCTAssertEqual(curve.value(at: 0), 0, "waits at 0 until the first key")
        XCTAssertEqual(curve.value(at: 0.05), 0, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 0.2), 1.1, accuracy: 1e-6)
        XCTAssertEqual(curve.value(at: 0.3), 0.97, accuracy: 1e-6)
        XCTAssertEqual(curve.value(at: 0.4), 1, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 5), 1)
        XCTAssertEqual(curve.duration, 0.4)
        XCTAssertEqual(curve.extent.upperBound, 1.1, accuracy: 1e-6)
    }

    func testSmoothNeverSwingsPastItsKeysAndPeaksExactlyAtAnOvershootKey() {
        let rising = MotionCurve.keyframes(keys((0, 0, .smooth), (0.1, 0.3, .smooth), (0.12, 0.9, .smooth), (0.5, 1, .smooth)))
        var previous = -1.0
        for step in 0...500 {
            let value = rising.value(at: 0.5 * Double(step) / 500)
            XCTAssertTrue(value >= previous - 1e-9, "monotone keys give a monotone curve")
            XCTAssertTrue(value <= 1 + 1e-9)
            previous = value
        }
        let overshoot = MotionCurve.keyframes(keys((0, 0, .smooth), (0.2, 1.12, .smooth), (0.4, 1, .smooth)))
        XCTAssertEqual(overshoot.extent.upperBound, 1.12, accuracy: 1e-3, "the peak is the key, not past it")
    }

    func testTimingCurvesMatchTheirEndsAndTheNamedCurves() {
        for (_, curve) in TimingCurve.named {
            XCTAssertEqual(curve.value(at: 0), 0)
            XCTAssertEqual(curve.value(at: 1), 1)
        }
        XCTAssertEqual(TimingCurve.linear.value(at: 0.37), 0.37, accuracy: 1e-5)
        XCTAssertTrue(TimingCurve.easeOut.value(at: 0.25) > 0.25, "ease out starts fast")
        XCTAssertTrue(TimingCurve.easeIn.value(at: 0.25) < 0.25, "ease in starts slow")
        let back = TimingCurve(0.34, 1.56, 0.64, 1)
        XCTAssertTrue(stride(from: 0.0, through: 1, by: 0.01).map(back.value).max()! > 1.05, "y past 1 overshoots")
        XCTAssertEqual(MotionEase(name: "easeOut"), .easeOut)
        XCTAssertEqual(MotionEase.easeInOut.name, "easeInOut")
        XCTAssertNil(MotionEase(name: "bouncy"))
    }

    func testASpringWaitsForItsDelayAndStretchingScalesTime() {
        let spring = MorphSpring(response: 0.3, dampingRatio: 0.8)
        let delayed = MotionCurve.spring(spring, delay: 0.1)
        XCTAssertEqual(delayed.value(at: 0.1), 0)
        XCTAssertEqual(delayed.value(at: 0.25), MotionCurve.spring(spring).value(at: 0.15), accuracy: 1e-12)
        let slower = delayed.stretched(by: 2)
        XCTAssertEqual(slower.value(at: 0.5), delayed.value(at: 0.25), accuracy: 1e-9)
        XCTAssertTrue(abs(slower.duration - 2 * delayed.duration) < 0.02)
    }

    func testASpringTurnedIntoKeyframesLooksTheSame() {
        let spring = MotionCurve.spring(MorphSpring(response: 0.4, dampingRatio: 0.6))
        let keys = spring.asKeyframes()
        XCTAssertTrue(keys.count <= CurveSketch.maximumKeys)
        let traced = MotionCurve.keyframes(keys)
        for step in 0...100 {
            let time = spring.duration * Double(step) / 100
            XCTAssertTrue(abs(traced.value(at: time) - spring.value(at: time)) < 0.04, "at \(time)")
        }
    }

    func testADrawnStrokeBecomesAFewKeyframesThatFollowIt() {
        // A wobbly hand-drawn ease out with an overshoot, drawn partly backwards.
        var stroke: [(time: Double, value: Double)] = []
        for step in 0...300 {
            let time = 0.02 + 0.5 * Double(step) / 300
            let s = Double(step) / 300
            let value = 0.08 + (1 - pow(1 - s, 3)) * 1.1 - max(0, s - 0.7) * 0.33 + sin(Double(step)) * 0.004
            stroke.append((time, value))
            if step == 150 { stroke.append((time - 0.05, 0.5)) }
        }
        let keys = CurveSketch.keyframes(from: stroke)
        XCTAssertTrue(keys.count >= 3 && keys.count <= CurveSketch.maximumKeys, "\(keys.count)")
        XCTAssertEqual(keys.first?.value, 0, "starts where the motion starts")
        XCTAssertEqual(keys.last?.value, 1, "ends where it ends")
        XCTAssertEqual(keys.first?.time ?? 0, 0.02, accuracy: 0.001, "keeps where the pen started as a delay")
        XCTAssertTrue(zip(keys, keys.dropFirst()).allSatisfy { $0.time < $1.time })
        let curve = MotionCurve.keyframes(keys)
        XCTAssertTrue(curve.extent.upperBound > 1.05, "the overshoot survives simplification")
    }

    func testAStrokeLiftedPastTheEndSettlesInsteadOfJumping() {
        let stroke = stride(from: 0.0, through: 0.3, by: 0.01).map { (time: $0, value: min($0 / 0.2, 1) * 1.1) }
        let keys = CurveSketch.keyframes(from: stroke)
        XCTAssertEqual(keys.last?.value, 1)
        XCTAssertTrue((keys.last?.time ?? 0) > 0.3, "a settle is added after the pen lifted at 110 %")
        XCTAssertEqual(keys[keys.count - 2].value, 1.1, accuracy: 0.01, "where the pen lifted is kept")
        let landed = CurveSketch.keyframes(from: stride(from: 0.0, through: 0.3, by: 0.01).map { (time: $0, value: min($0 / 0.2, 1)) })
        XCTAssertEqual(landed.last?.time ?? 0, 0.3, accuracy: 0.001, "a stroke lifted at the end needs no settle")
    }

    func testAReversedOpeningIsTheMatchingClosing() {
        let opening = MotionCurve.spring(MorphSpring(response: 0.3, dampingRatio: 1), delay: 0.05)
        let closing = opening.reversed()
        XCTAssertEqual(closing.value(at: 0), 0)
        XCTAssertEqual(closing.value(at: closing.duration), 1)
        XCTAssertTrue(closing.duration < opening.duration - 0.03, "the opening's wait is not kept as a hold")
        for step in 1..<20 {
            let t = opening.duration * Double(step) / 20
            XCTAssertEqual(closing.value(at: t), 1 - opening.value(at: opening.duration - t), accuracy: 0.05)
        }
    }

    func testClosingIsPlayedForwardOnlyWhateverItsCurve() {
        let bouncy = NotchMorph.Motion(width: .spring(MorphSpring(response: 0.4, dampingRatio: 0.4)),
                                       height: .keyframes(keys((0, 0, .smooth), (0.1, 1.2, .smooth), (0.2, 0.6, .smooth), (0.3, 1, .smooth))))
        let animation = DropyAnimation(name: "Bouncy close", open: bouncy, resize: bouncy, close: bouncy,
                                       content: MotionStyle.balanced.content)
        XCTAssertTrue(animation.close.isMonotonic)
        XCTAssertFalse(animation.open.isMonotonic)
        let open = NotchShape.open(body: CGRect(x: 40, y: 40, width: 600, height: 400))
        let notch = NotchShape.notch(size: CGSize(width: 200, height: 32), in: CGSize(width: 680, height: 440))
        let frames = NotchMorph.frames(from: open, to: notch, motion: animation.morph.close).shapes
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertTrue(b.body.width <= a.body.width + 1e-6 && b.body.height <= a.body.height + 1e-6,
                          "never grows back out of the notch")
            XCTAssertTrue(b.body.width >= notch.body.width - 1e-6 && b.body.height >= notch.body.height - 1e-6)
        }
        XCTAssertEqual(animation.morph.close.extent, 0...1)
    }

    func testTheWindowMarginHoldsABouncyAnimation() throws {
        let animation = try XCTUnwrap(DropyAnimation.gallery.first { $0.id == "elastic-drop" }?.animation)
        let size = CGSize(width: 900, height: 560)
        let margin = NotchMorph.overshootMargin(for: size, reach: animation.morph.reach)
        XCTAssertTrue(margin > NotchMorph.overshootMargin(for: size), "a 14 % overshoot needs more room than the built-ins")
        let canvas = CGSize(width: size.width + 2 * margin, height: size.height + margin)
        let notch = NotchShape.notch(size: CGSize(width: 200, height: 32), in: canvas)
        let open = NotchShape.open(body: CGRect(origin: CGPoint(x: margin, y: margin), size: size))
        let window = CGRect(origin: .zero, size: canvas)
        for shape in NotchMorph.frames(from: notch, to: open, motion: animation.morph.open).shapes {
            XCTAssertTrue(window.contains(shape.fillPath.boundingBoxOfPath.insetBy(dx: 0.5, dy: 0.5)))
        }
    }
}
