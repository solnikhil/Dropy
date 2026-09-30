import CoreGraphics
import Foundation

/// Modifier keys held during a preview event, independent of AppKit so the decisions
/// below can be tested.
public struct PreviewModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = PreviewModifiers(rawValue: 1 << 0)
    public static let control = PreviewModifiers(rawValue: 1 << 1)
    public static let option = PreviewModifiers(rawValue: 1 << 2)
    public static let shift = PreviewModifiers(rawValue: 1 << 3)
    /// Any of these makes a pointer event a different gesture (Command-click, Option-scroll…).
    public static let gesture: PreviewModifiers = [.command, .control, .option, .shift]
}

/// Decides what a key pressed on the interactive preview means, before any routing.
///
/// Only committed text is ever forwarded. Everything that composes (input methods, dead
/// keys) or that names an action rather than text (shortcuts, editing and function keys)
/// is refused with a visible reason. Composition is stateful: a dead key changes the
/// meaning of the key after it (Option-E then E is "é"), so that next key is refused too,
/// rather than sent as the wrong character.
public struct PreviewKeyInput: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Committed text to type into the exact window.
        case text(String)
        /// Refused as a gesture Dropy does not route (shortcut, composition).
        case refuse(InputKind)
        /// A key with no text: return, tab, delete, arrows, function keys.
        case unsupportedKey
    }

    /// A dead key was pressed and the key that completes it has not arrived yet.
    public private(set) var composing = false

    public init() {}

    /// - Parameters:
    ///   - characters: the text the key produced with modifiers (NSEvent.characters);
    ///     empty for a dead key.
    ///   - charactersIgnoringModifiers: the key's base character; non-empty for a dead key.
    ///   - inputMethodActive: the current input source composes (e.g. Japanese, Chinese).
    public mutating func classify(characters: String?, charactersIgnoringModifiers: String?,
                                  modifiers: PreviewModifiers, inputMethodActive: Bool) -> Decision {
        if !modifiers.isDisjoint(with: [.command, .control]) {
            composing = false
            return .refuse(.keyShortcut)
        }
        if inputMethodActive {
            composing = false
            return .refuse(.imeComposition)
        }
        guard let characters, !characters.isEmpty else {
            // A dead key produces no characters but has a base key. Its successor
            // completes the composition, so that key must not be typed on its own.
            if let base = charactersIgnoringModifiers, !base.isEmpty {
                composing = true
                return .refuse(.imeComposition)
            }
            composing = false
            return .unsupportedKey
        }
        if composing {
            composing = false
            return .refuse(.imeComposition)
        }
        guard characters.unicodeScalars.allSatisfy(Self.isCommittedText) else { return .unsupportedKey }
        return .text(characters)
    }

    /// Printable text: not a control character (return, tab, delete, escape) and not in
    /// AppKit's function-key range (arrows, F-keys, Home, End: U+F700–U+F8FF).
    static func isCommittedText(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
    }
}

/// Decides what a pointer gesture on the interactive preview means, before any routing.
/// Only a plain single click and plain, non-momentum scrolling are forwarded.
public enum PreviewPointerInput {
    /// Pointer travel (points) after which a press is a drag, not a click.
    public static let dragThreshold: CGFloat = 4
    /// Line-based wheels report small deltas; AppKit scrolls about this many points a line.
    public static let pointsPerLine: CGFloat = 10

    public enum Press: Equatable, Sendable {
        /// Track the press; it becomes a click on release unless it turns into a drag.
        case track
        /// Refused: a double-click (its second press) or a modified click.
        case refuse(InputKind)
    }

    public static func press(clickCount: Int, modifiers: PreviewModifiers) -> Press {
        modifiers.isDisjoint(with: .gesture) && clickCount == 1 ? .track : .refuse(.pointerClick)
    }

    public static func isDrag(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) > dragThreshold
    }

    public enum Scroll: Equatable, Sendable {
        /// Scroll by this delta (points; positive height scrolls toward the top).
        case send(CGSize)
        /// Refused: modified scrolling (zoom, horizontal-by-Shift…) or momentum, which
        /// continues after the person has stopped and cannot be tied to their intent.
        case refuse(InputKind)
        /// Nothing to do: a phase event with no movement.
        case ignore
    }

    public static func scroll(delta: CGSize, precise: Bool, momentum: Bool, modifiers: PreviewModifiers) -> Scroll {
        guard modifiers.isDisjoint(with: .gesture), !momentum else { return .refuse(.scroll) }
        guard delta.width.isFinite, delta.height.isFinite else { return .ignore }
        let factor = precise ? 1 : pointsPerLine
        let points = CGSize(width: delta.width * factor, height: delta.height * factor)
        // Routes round to whole points; less than half a point moves nothing.
        guard abs(points.width) >= 0.5 || abs(points.height) >= 0.5 else { return .ignore }
        return .send(points)
    }
}
