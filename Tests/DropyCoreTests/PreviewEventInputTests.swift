import CoreGraphics
import Foundation
import XCTest
import DropyCore

final class PreviewEventInputTests: XCTestCase {
    private func key(_ input: inout PreviewKeyInput, _ characters: String?, base: String? = nil,
                     _ modifiers: PreviewModifiers = [], ime: Bool = false) -> PreviewKeyInput.Decision {
        input.classify(characters: characters, charactersIgnoringModifiers: base ?? characters,
                       modifiers: modifiers, inputMethodActive: ime)
    }

    func testCommittedTextIsTypedIncludingShiftAndOptionCharacters() {
        var input = PreviewKeyInput()
        XCTAssertEqual(key(&input, "a"), .text("a"))
        XCTAssertEqual(key(&input, "A", base: "a", .shift), .text("A"))
        // Option-A on a US layout commits "å" directly; it is text, not a shortcut.
        XCTAssertEqual(key(&input, "å", base: "a", .option), .text("å"))
        XCTAssertEqual(key(&input, " "), .text(" "))
        XCTAssertEqual(key(&input, "😀"), .text("😀"))
    }

    func testShortcutsAreRefusedAsShortcuts() {
        var input = PreviewKeyInput()
        XCTAssertEqual(key(&input, "k", .command), .refuse(.keyShortcut))
        XCTAssertEqual(key(&input, "\u{1}", base: "a", .control), .refuse(.keyShortcut))
        XCTAssertEqual(key(&input, "Z", base: "z", [.command, .shift]), .refuse(.keyShortcut))
    }

    func testAnActiveInputMethodRefusesEveryKey() {
        var input = PreviewKeyInput()
        // A composing input source (Japanese, Chinese…) reports plain letters that it
        // would turn into other text; typing them raw would be wrong.
        XCTAssertEqual(key(&input, "k", ime: true), .refuse(.imeComposition))
        XCTAssertEqual(key(&input, "a", ime: true), .refuse(.imeComposition))
        // A shortcut is still reported as a shortcut.
        XCTAssertEqual(key(&input, "k", .command, ime: true), .refuse(.keyShortcut))
    }

    func testADeadKeyRefusesItselfAndTheKeyThatCompletesIt() {
        var input = PreviewKeyInput()
        // Option-E: no characters, base "e". The next key completes the accent.
        XCTAssertEqual(key(&input, "", base: "e", .option), .refuse(.imeComposition))
        XCTAssertTrue(input.composing)
        XCTAssertEqual(key(&input, "é", base: "e"), .refuse(.imeComposition))
        XCTAssertFalse(input.composing)
        // After that, typing is normal again.
        XCTAssertEqual(key(&input, "e"), .text("e"))
    }

    func testAShortcutOrInputMethodEndsAPendingDeadKey() {
        var input = PreviewKeyInput()
        _ = key(&input, "", base: "u", .option)
        XCTAssertEqual(key(&input, "c", .command), .refuse(.keyShortcut))
        XCTAssertEqual(key(&input, "c"), .text("c"))
        _ = key(&input, "", base: "u", .option)
        XCTAssertEqual(key(&input, "a", ime: true), .refuse(.imeComposition))
        XCTAssertEqual(key(&input, "a"), .text("a"))
    }

    func testEditingAndFunctionKeysAreUnsupported() {
        var input = PreviewKeyInput()
        for characters in ["\r", "\t", "\u{7F}", "\u{1B}", "\u{F702}", "\u{F704}", "\u{F729}", "\u{F8FF}", "a\r"] {
            XCTAssertEqual(key(&input, characters), .unsupportedKey, characters.debugDescription)
        }
        // No characters and no base key (e.g. a bare modifier-like key).
        XCTAssertEqual(key(&input, nil, base: nil), .unsupportedKey)
        XCTAssertEqual(key(&input, "", base: ""), .unsupportedKey)
        XCTAssertFalse(input.composing)
    }

    func testOnlyAPlainSingleClickIsTracked() {
        XCTAssertEqual(PreviewPointerInput.press(clickCount: 1, modifiers: []), .track)
        XCTAssertEqual(PreviewPointerInput.press(clickCount: 2, modifiers: []), .refuse(.pointerClick))
        XCTAssertEqual(PreviewPointerInput.press(clickCount: 3, modifiers: []), .refuse(.pointerClick))
        for modifier in [PreviewModifiers.command, .control, .option, .shift] {
            XCTAssertEqual(PreviewPointerInput.press(clickCount: 1, modifiers: modifier), .refuse(.pointerClick))
        }
    }

    func testDragStartsOnlyPastTheThreshold() {
        let start = CGPoint(x: 100, y: 100)
        XCTAssertFalse(PreviewPointerInput.isDrag(from: start, to: CGPoint(x: 104, y: 100)))
        XCTAssertFalse(PreviewPointerInput.isDrag(from: start, to: CGPoint(x: 102.8, y: 102.8)))
        XCTAssertTrue(PreviewPointerInput.isDrag(from: start, to: CGPoint(x: 103, y: 103)))
        XCTAssertTrue(PreviewPointerInput.isDrag(from: start, to: CGPoint(x: 100, y: 95)))
    }

    func testScrollSendsPlainDeltasInPointsAndRefusesModifiedOrMomentum() {
        XCTAssertEqual(PreviewPointerInput.scroll(delta: CGSize(width: 0, height: -12.5), precise: true, momentum: false,
                                                  modifiers: []), .send(CGSize(width: 0, height: -12.5)))
        // A line-based wheel: one line is ten points.
        XCTAssertEqual(PreviewPointerInput.scroll(delta: CGSize(width: 0, height: 3), precise: false, momentum: false,
                                                  modifiers: []), .send(CGSize(width: 0, height: 30)))
        XCTAssertEqual(PreviewPointerInput.scroll(delta: CGSize(width: 0, height: 5), precise: true, momentum: true,
                                                  modifiers: []), .refuse(.scroll))
        XCTAssertEqual(PreviewPointerInput.scroll(delta: CGSize(width: 0, height: 5), precise: true, momentum: false,
                                                  modifiers: .option), .refuse(.scroll))
        XCTAssertEqual(PreviewPointerInput.scroll(delta: CGSize(width: 0, height: 5), precise: true, momentum: false,
                                                  modifiers: .shift), .refuse(.scroll))
        // Phase events with no movement, and nonsense deltas, send nothing.
        XCTAssertEqual(PreviewPointerInput.scroll(delta: .zero, precise: true, momentum: false, modifiers: []), .ignore)
        XCTAssertEqual(PreviewPointerInput.scroll(delta: CGSize(width: 0.2, height: -0.3), precise: true, momentum: false,
                                                  modifiers: []), .ignore)
        XCTAssertEqual(PreviewPointerInput.scroll(delta: CGSize(width: 0, height: CGFloat.nan), precise: true, momentum: false,
                                                  modifiers: []), .ignore)
    }
}
