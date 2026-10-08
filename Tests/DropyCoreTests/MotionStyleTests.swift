import XCTest
import CoreGraphics
import Foundation
import DropyCore

final class MotionStyleTests: XCTestCase {
    private let size = CGSize(width: 1200, height: 700)
    private var margin: CGFloat { NotchMorph.overshootMargin(for: size) }
    private var canvas: CGSize { CGSize(width: size.width + 2 * margin, height: size.height + margin) }
    private var notch: NotchShape { NotchShape.notch(size: CGSize(width: 208, height: 37.5), in: canvas) }
    private var open: NotchShape { NotchShape.open(body: CGRect(origin: CGPoint(x: margin, y: margin), size: size)) }

    private func peak(_ curve: MotionCurve) -> Double {
        stride(from: 0.0, to: 2, by: 0.002).map(curve.value).max() ?? 0
    }

    func testRapidIsFasterThanBalancedWhichIsFasterThanSmooth() {
        for keyPath in [\NotchMorph.Motions.open, \.close, \.resize] {
            let durations = [MotionStyle.rapid, .balanced, .smooth].map { $0.morph[keyPath: keyPath].duration }
            XCTAssertTrue(durations[0] < durations[1] && durations[1] < durations[2], "\(durations)")
        }
        let reveals = [MotionStyle.rapid, .balanced, .smooth].map { $0.content.revealDuration + $0.content.revealDelay }
        XCTAssertTrue(reveals[0] < reveals[1] && reveals[1] < reveals[2])
    }

    func testEveryStyleOpensAndClosesInUnderASecond() {
        for style in MotionStyle.allCases {
            XCTAssertTrue(style.morph.open.duration < 1, "\(style) open \(style.morph.open.duration)")
            XCTAssertTrue(style.morph.close.duration < 0.8, "\(style) close \(style.morph.close.duration)")
        }
        XCTAssertTrue(MotionStyle.rapid.morph.open.duration < 0.4, "rapid feels instant")
    }

    func testClosingNeverOvershootsInAnyStyle() {
        for style in MotionStyle.allCases {
            XCTAssertTrue(peak(style.morph.close.width) <= 1 && peak(style.morph.close.height) <= 1, "\(style)")
        }
    }

    func testOnlyTheSofterStylesSettleVisibly() {
        XCTAssertTrue(peak(MotionStyle.rapid.morph.open.height) < 1.002, "rapid lands without a bounce")
        let balanced = peak(MotionStyle.balanced.morph.open.height)
        let smooth = peak(MotionStyle.smooth.morph.open.height)
        XCTAssertTrue(balanced > 1.003 && balanced < smooth && smooth < 1.03)
    }

    func testOvershootStaysInsideTheWindowForEveryStyle() {
        let window = CGRect(origin: .zero, size: canvas)
        for style in MotionStyle.allCases {
            for shape in NotchMorph.frames(from: notch, to: open, motion: style.morph.open).shapes {
                XCTAssertTrue(window.contains(shape.fillPath.boundingBoxOfPath.insetBy(dx: 0.5, dy: 0.5)), "\(style)")
            }
        }
    }

    func testRapidSkipsTheBlurAndOlderSettingsGetBalanced() throws {
        XCTAssertEqual(MotionStyle.rapid.content.blurRadius, 0)
        XCTAssertTrue(MotionStyle.smooth.content.blurRadius > MotionStyle.balanced.content.blurRadius)
        let saved = #"{"sizePreset":"medium"}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(DropyPreferences.self, from: saved).motionStyle, .balanced)
    }
}
