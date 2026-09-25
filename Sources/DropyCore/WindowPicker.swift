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

    public init(processID: Int32, windowID: UInt32, applicationName: String, title: String,
                layer: Int, size: CGSize, isOnScreen: Bool) {
        self.processID = processID
        self.windowID = windowID
        self.applicationName = applicationName
        self.title = title
        self.layer = layer
        self.size = size
        self.isOnScreen = isOnScreen
    }
}

public struct PickerEntry: Equatable, Sendable {
    public let processID: Int32
    public let windowID: UInt32
    public let label: String
}

public enum WindowPicker {
    public static let minimumSize = CGSize(width: 160, height: 100)

    /// Choose document-like windows and give every entry a label a person can tell apart.
    /// - Only the normal window layer: floating panels, menus and overlays are excluded.
    /// - Per app, titled windows are offered. An app with none offers its largest
    ///   on-screen untitled window; an off-screen untitled one is usually a hidden helper.
    /// - Entries that would share a label get a creation-order suffix, and windows that
    ///   are not on screen say so because their preview will be paused.
    public static func entries(from windows: [WindowSummary]) -> [PickerEntry] {
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
        return zip(sorted, baseLabels).map { window, base in
            var label = base
            if let total = counts[base], total > 1 {
                let ordinal = (seen[base] ?? 0) + 1
                seen[base] = ordinal
                label += " (\(ordinal) of \(total))"
            }
            if !window.isOnScreen { label += " · not visible" }
            return PickerEntry(processID: window.processID, windowID: window.windowID, label: label)
        }
    }

    private static func baseLabel(_ window: WindowSummary) -> String {
        window.title.isEmpty ? window.applicationName : "\(window.applicationName) — \(window.title)"
    }
}
