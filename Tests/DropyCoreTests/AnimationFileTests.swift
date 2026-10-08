import XCTest
import CoreGraphics
import Foundation
import DropyCore

final class AnimationFileTests: XCTestCase {
    private func read(_ json: String) -> AnimationReadResult {
        AnimationFile.read(Data(json.utf8), fallbackName: "from-file")
    }

    private func paths(_ issues: [AnimationIssue]) -> [String] { issues.map(\.path) }

    func testEveryBuiltInAndExampleRoundTripsWithoutAnIssue() throws {
        let all = MotionStyle.allCases.map(\.animation) + DropyAnimation.gallery.map(\.animation)
        for animation in all {
            let result = AnimationFile.read(AnimationFile.data(for: animation))
            XCTAssertEqual(result.issues, [], animation.name)
            XCTAssertEqual(result.animation, animation, animation.name)
            let code = AnimationFile.shareCode(for: animation)
            XCTAssertTrue(code.hasPrefix(AnimationFile.shareCodePrefix) && !code.contains("\n"))
            XCTAssertEqual(AnimationFile.read(shareCode: code).animation, animation, "share code \(animation.name)")
        }
    }

    func testOnlyTheMarkerIsRequiredAndTheRestComesFromBasedOn() throws {
        let plain = try XCTUnwrap(read(#"{ "dropyAnimation": 1 }"#).animation)
        XCTAssertEqual(plain.name, "from-file")
        XCTAssertEqual(plain.morph, MotionStyle.balanced.morph)
        XCTAssertEqual(plain.content, MotionStyle.balanced.content)
        let rapid = try XCTUnwrap(read(#"{ "dropyAnimation": 1, "basedOn": "rapid", "name": "Mine" }"#).animation)
        XCTAssertEqual(rapid.morph, MotionStyle.rapid.morph)
        XCTAssertEqual(rapid.name, "Mine")
        let example = try XCTUnwrap(read(#"{ "dropyAnimation": 1, "basedOn": "springy" }"#).animation)
        XCTAssertEqual(example.open, DropyAnimation.gallery[0].animation.open)
    }

    func testCommentsTrailingCommasShortFormsAndOneCurveForBoth() throws {
        let result = read("""
        {
          // Written by hand.
          "dropyAnimation": 1,
          "open": { "spring": { "response": 0.3, "bounce": 0.2 } },
          "close": { "height": { "keyframes": [[0, 0], [0.12, 1, "easeIn"],] } },
        }
        """)
        XCTAssertEqual(result.issues, [])
        let animation = try XCTUnwrap(result.animation)
        XCTAssertEqual(animation.open.width, .spring(MorphSpring(response: 0.3, dampingRatio: 0.8)))
        XCTAssertEqual(animation.open.height, animation.open.width)
        XCTAssertEqual(animation.close.height, .keyframes([MotionKeyframe(time: 0, value: 0),
                                                          MotionKeyframe(time: 0.12, value: 1, ease: .easeIn)]))
        XCTAssertEqual(animation.close.width, MotionStyle.balanced.morph.close.width, "the other part is kept")
    }

    func testProblemsNameTheExactValue() {
        XCTAssertEqual(paths(read("not json").errors), [""])
        XCTAssertEqual(paths(read(#"{ "name": "x" }"#).errors), ["dropyAnimation"])
        XCTAssertTrue(read(#"{ "dropyAnimation": 2 }"#).errors.first?.message.contains("newer Dropy") == true)
        let wrongType = read(#"{ "dropyAnimation": 1, "open": { "height": { "spring": { "response": "fast" } } } }"#)
        XCTAssertNil(wrongType.animation)
        XCTAssertEqual(paths(wrongType.errors), ["open.height.spring.response"])
        let both = read(#"{ "dropyAnimation": 1, "open": { "width": { "spring": { "response": 0.3 }, "keyframes": [] } } }"#)
        XCTAssertEqual(paths(both.errors), ["open.width"])
        let missing = read(#"{ "dropyAnimation": 1, "resize": { "width": { "keyframes": [ { "time": 0 }, { "time": 0.2, "value": 1 } ] } } }"#)
        XCTAssertEqual(paths(missing.errors), ["resize.width.keyframes[0].value"])
    }

    func testTyposGetASuggestionAndAreIgnored() throws {
        let result = read(#"{ "dropyAnimation": 1, "open": { "width": { "spring": { "respnse": 0.2, "response": 0.3 } } }, "contnet": {} }"#)
        XCTAssertNotNil(result.animation)
        let typo = try XCTUnwrap(result.warnings.first { $0.path == "open.width.spring.respnse" })
        XCTAssertTrue(typo.message.contains("“response”"), typo.message)
        XCTAssertTrue(result.warnings.contains { $0.path == "contnet" && $0.message.contains("“content”") })
        let ease = read(#"{ "dropyAnimation": 1, "open": { "keyframes": [[0, 0], [0.3, 1, "easeOutt"]] } }"#)
        XCTAssertTrue(ease.warnings.first?.message.contains("“easeOut”") == true)
    }

    func testValuesOutsideTheLimitsAreBroughtInsideWithAWarning() throws {
        let result = read("""
        { "dropyAnimation": 1,
          "open": { "width": { "spring": { "response": 0.01, "damping": 0.1 } },
                    "height": { "keyframes": [ { "time": 0.1, "value": 0.4 }, { "time": 0.3, "value": 2 }, { "time": 0.4, "value": 0.9 } ] } },
          "content": { "blur": 80, "startScale": 0.1 } }
        """)
        let animation = try XCTUnwrap(result.animation)
        XCTAssertEqual(animation.open.width, .spring(MorphSpring(response: AnimationLimits.response.lowerBound,
                                                                  dampingRatio: AnimationLimits.damping.lowerBound)))
        guard case .keyframes(let keys) = animation.open.height else { return XCTFail("keyframes") }
        XCTAssertEqual(keys.map(\.value), [0, AnimationLimits.keyValue.upperBound, 1], "starts at 0, clamped, ends at 1")
        XCTAssertEqual(keys.first?.time, 0.1, "a later first key is a delay")
        XCTAssertEqual(animation.content.blurRadius, CGFloat(AnimationLimits.blur.upperBound))
        XCTAssertEqual(animation.content.restScale, CGFloat(AnimationLimits.startScale.lowerBound))
        XCTAssertEqual(Set(paths(result.warnings)), [
            "open.width.spring.response", "open.width.spring.damping", "open.height.keyframes[1].value",
            "open.height.keyframes[0].value", "open.height.keyframes[2].value", "content.blur", "content.startScale",
        ])
    }

    func testOutOfOrderKeyframesAreSortedAndAMotionTooLongIsSpedUp() throws {
        let result = read("""
        { "dropyAnimation": 1,
          "close": { "keyframes": [ [0, 0], [1.8, 1], [0.9, 0.5] ] } }
        """)
        let animation = try XCTUnwrap(result.animation)
        XCTAssertTrue(result.warnings.contains { $0.path == "close.keyframes" })
        XCTAssertTrue(result.warnings.contains { $0.path == "close" && $0.message.contains("sped up") })
        XCTAssertEqual(animation.close.duration, AnimationLimits.longest(.close), accuracy: 0.002)
        guard case .keyframes(let keys) = animation.close.width else { return XCTFail("keyframes") }
        XCTAssertEqual(keys.map(\.value), [0, 0.5, 1])
    }

    func testABouncingCloseIsAcceptedButExplained() throws {
        let result = read(#"{ "dropyAnimation": 1, "close": { "spring": { "response": 0.3, "damping": 0.5 } } }"#)
        XCTAssertNotNil(result.animation)
        XCTAssertTrue(result.warnings.contains { $0.path == "close" && $0.message.contains("forward-only") })
    }

    func testFilesAreWrittenInReadingOrderWithOneKeyframePerLine() {
        let text = String(decoding: AnimationFile.data(for: DropyAnimation.gallery[1].animation), as: UTF8.self)
        let order = ["\"dropyAnimation\"", "\"name\"", "\"open\"", "\"resize\"", "\"close\"", "\"content\""]
        let positions = order.compactMap { text.range(of: $0)?.lowerBound }
        XCTAssertEqual(positions.count, order.count)
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertTrue(text.contains(#"{ "time": 0.2, "value": 1.14, "ease": "easeOut" }"#))
    }

    func testABrokenShareCodeSaysSo() {
        XCTAssertEqual(AnimationFile.read(shareCode: "hello").errors.count, 1)
        let code = AnimationFile.shareCode(for: MotionStyle.smooth.animation)
        XCTAssertNil(AnimationFile.read(shareCode: String(code.dropLast(12))).animation)
    }

    func testCostFollowsTheBlur() {
        XCTAssertEqual(MotionStyle.rapid.animation.cost.level, .light)
        XCTAssertEqual(MotionStyle.balanced.animation.cost.level, .moderate)
        XCTAssertEqual(MotionStyle.smooth.animation.cost.level, .heavy)
    }

    func testTheFilmstripRendersEveryExample() throws {
        for (id, animation) in DropyAnimation.gallery {
            let png = try XCTUnwrap(AnimationFilmstrip.png(for: animation), id)
            XCTAssertTrue(png.count > 10_000, "\(id) \(png.count) bytes")
        }
    }

    func testTheGuideCoversTheFormat() {
        let guide = AnimationGuide.readme(folder: "/tmp/animations", command: "dropy animation")
        for needle in ["/tmp/animations", "dropy animation check", "\"dropyAnimation\": 1", "keyframes", "revealCurve",
                       "forward-only", "basedOn"] {
            XCTAssertTrue(guide.contains(needle), needle)
        }
        XCTAssertTrue(guide.hasPrefix(AnimationGuide.generatedMarker))
    }
}
