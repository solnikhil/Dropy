import Foundation
import CoreGraphics

/// The facts the picker needs about one shareable window, independent of ScreenCaptureKit.
public struct WindowSummary: Equatable, Sendable {
    public let processID: Int32
    public let windowID: UInt32
    public let applicationName: String
    public let title: String
    public let layer: Int
    public let size: CGSize
    public let isOnScreen: Bool
    /// The owning app's bundle identifier, when it has one. Pinning is keyed by it, so a
    /// bare executable can be previewed but not pinned.
    public let bundleIdentifier: String?

    public init(processID: Int32, windowID: UInt32, applicationName: String, title: String,
                layer: Int, size: CGSize, isOnScreen: Bool, bundleIdentifier: String? = nil) {
        self.processID = processID
        self.windowID = windowID
        self.applicationName = applicationName
        self.title = title
        self.layer = layer
        self.size = size
        self.isOnScreen = isOnScreen
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct PickerEntry: Equatable, Sendable {
    public let processID: Int32
    public let windowID: UInt32
    public let label: String
    public let bundleIdentifier: String?
    /// The owning app is pinned, so this entry is offered before the unpinned ones.
    public let isPinned: Bool
    /// 1–9 when a number key in the picker selects this entry. Only pinned entries get a
    /// key, and only the first nine of them: a tenth number key does not exist.
    public let quickSelectKey: Int?

    public init(processID: Int32, windowID: UInt32, label: String, bundleIdentifier: String? = nil,
                isPinned: Bool = false, quickSelectKey: Int? = nil) {
        self.processID = processID
        self.windowID = windowID
        self.label = label
        self.bundleIdentifier = bundleIdentifier
        self.isPinned = isPinned
        self.quickSelectKey = quickSelectKey
    }

    /// The label as the picker shows it: a quick-select number in front when there is one,
    /// so the key to press is visible rather than something to be remembered.
    public var displayTitle: String {
        guard let quickSelectKey else { return label }
        return "\(quickSelectKey) · \(label)"
    }
}

/// Which apps are offered first in the picker, and which number key reaches them.
public enum AppPinning {
    /// Number keys 1–9. There is no 0 key: counting from 1 matches the printed label.
    public static let maximumQuickSelectKeys = 9

    /// Drops blanks and repeats, keeping the order the apps were pinned in. A pin list with
    /// a repeat in it could not be numbered unambiguously.
    public static func normalized(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    /// Pins an app at the end of the list, or unpins it. Pinning at the end keeps the
    /// numbers already learned for the other apps.
    public static func toggled(_ identifiers: [String], bundleIdentifier: String) -> [String] {
        let pins = normalized(identifiers)
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pins }
        if pins.contains(trimmed) { return pins.filter { $0 != trimmed } }
        return pins + [trimmed]
    }

    /// The quick-select number a key press asks for, or nil.
    ///
    /// - Only a bare number key: Command-1 and friends belong to the system and to menus,
    ///   and Option-1 is a different character altogether.
    /// - Only while the picker is showing. With a live preview the same key can be text for
    ///   the source window, and silently switching windows instead of typing would be worse
    ///   than doing nothing.
    public static func quickSelect(characters: String?, modifiers: PreviewModifiers,
                                   pickerShowing: Bool) -> Int? {
        guard pickerShowing, modifiers.isDisjoint(with: .gesture),
              let characters, characters.count == 1,
              let digit = characters.first.flatMap({ $0.wholeNumberValue }),
              (1...maximumQuickSelectKeys).contains(digit) else { return nil }
        return digit
    }
}

public enum WindowPicker {
    public static let minimumSize = CGSize(width: 160, height: 100)

    /// Choose document-like windows and give every entry a label a person can tell apart.
    /// - Only the normal window layer: floating panels, menus and overlays are excluded.
    /// - Per app, titled windows are offered. An app with none offers its largest
    ///   on-screen untitled window; an off-screen untitled one is usually a hidden helper.
    /// - Entries that would share a label get a creation-order suffix, and windows that
    ///   are not on screen say so because their preview will be paused.
    /// - Windows of pinned apps come first, in the order those apps were pinned, and the
    ///   first nine of them carry the number key that selects them.
    public static func entries(from windows: [WindowSummary], pinned: [String] = []) -> [PickerEntry] {
        let candidates = windows.filter {
            $0.layer == 0 && !$0.applicationName.isEmpty &&
                $0.size.width >= minimumSize.width && $0.size.height >= minimumSize.height
        }
        let chosen = Dictionary(grouping: candidates, by: \.processID).values.flatMap { app in
            let titled = app.filter { !$0.title.isEmpty }
            if !titled.isEmpty { return titled }
            return app.filter(\.isOnScreen)
                .max { $0.size.width * $0.size.height < $1.size.width * $1.size.height }
                .map { [$0] } ?? []
        }
        let sorted = chosen.sorted { lhs, rhs in
            let byApp = lhs.applicationName.localizedStandardCompare(rhs.applicationName)
            if byApp != .orderedSame { return byApp == .orderedAscending }
            let byTitle = lhs.title.localizedStandardCompare(rhs.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            if lhs.processID != rhs.processID { return lhs.processID < rhs.processID }
            return lhs.windowID < rhs.windowID
        }
        let baseLabels = sorted.map(baseLabel)
        let counts = Dictionary(baseLabels.map { ($0, 1) }, uniquingKeysWith: +)
        var seen: [String: Int] = [:]
        let labelled: [(window: WindowSummary, label: String)] = zip(sorted, baseLabels).map { window, base in
            var label = base
            if let total = counts[base], total > 1 {
                let ordinal = (seen[base] ?? 0) + 1
                seen[base] = ordinal
                label += " (\(ordinal) of \(total))"
            }
            if !window.isOnScreen { label += " · not visible" }
            return (window, label)
        }
        return numbered(order(labelled, pinned: pinned))
    }

    /// Pinned apps first in pin order, then everything else in the order it was labelled.
    /// The sort is made stable by hand: `sorted(by:)` gives no such guarantee, and an
    /// unstable picker would reshuffle rows between refreshes.
    private static func order(_ labelled: [(window: WindowSummary, label: String)],
                              pinned: [String]) -> [(window: WindowSummary, label: String, pin: Int?)] {
        let pins = AppPinning.normalized(pinned)
        let rank = Dictionary(uniqueKeysWithValues: pins.enumerated().map { ($0.element, $0.offset) })
        let ranked = labelled.map { item in
            (window: item.window, label: item.label, pin: item.window.bundleIdentifier.flatMap { rank[$0] })
        }
        return ranked.enumerated().sorted { lhs, rhs in
            let left = lhs.element.pin ?? Int.max
            let right = rhs.element.pin ?? Int.max
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func numbered(_ ordered: [(window: WindowSummary, label: String, pin: Int?)]) -> [PickerEntry] {
        var assigned = 0
        return ordered.map { item in
            var key: Int?
            if item.pin != nil, assigned < AppPinning.maximumQuickSelectKeys {
                assigned += 1
                key = assigned
            }
            return PickerEntry(processID: item.window.processID, windowID: item.window.windowID,
                               label: item.label, bundleIdentifier: item.window.bundleIdentifier,
                               isPinned: item.pin != nil, quickSelectKey: key)
        }
    }

    private static func baseLabel(_ window: WindowSummary) -> String {
        window.title.isEmpty ? window.applicationName : "\(window.applicationName) — \(window.title)"
    }
}
