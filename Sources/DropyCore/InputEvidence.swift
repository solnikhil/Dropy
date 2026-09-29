import CoreGraphics
import Foundation

/// Verified input evidence per source app, generated from harness results by
/// `InputProbe evidence` and shipped as `InputEvidence.json`. An app without an entry,
/// or a different macOS major version than the one tested, gets no capabilities:
/// Dropy shows it view-only rather than extrapolating.
public struct InputEvidence: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        public var bundleIdentifier: String
        /// The app version the trials ran against, when known.
        public var appVersion: String?
        /// The `docs/input-probe` report the trials came from.
        public var report: String
        public var trials: [InputTrial]

        public init(bundleIdentifier: String, appVersion: String?, report: String, trials: [InputTrial]) {
            self.bundleIdentifier = bundleIdentifier
            self.appVersion = appVersion
            self.report = report
            self.trials = trials
        }
    }

    public static let currentFormat = 1
    public var format: Int
    /// e.g. "27.0 (26A428)".
    public var macOS: String
    public var macOSMajor: Int
    public var sources: [Source]

    public init(macOS: String, macOSMajor: Int, sources: [Source]) {
        format = Self.currentFormat
        self.macOS = macOS
        self.macOSMajor = macOSMajor
        self.sources = sources
    }

    /// Capabilities for one running app. Empty for an unknown format, another macOS
    /// major version or an app that was never tested.
    public func capabilities(for bundleIdentifier: String?, macOSMajor running: Int) -> InputCapabilities {
        guard format == Self.currentFormat, running == macOSMajor, let bundleIdentifier else {
            return InputCapabilities(trials: [])
        }
        return InputCapabilities(trials: sources.filter { $0.bundleIdentifier == bundleIdentifier }.flatMap(\.trials))
    }
}

/// Maps a point in the preview to the source window, through the image actually drawn.
///
/// The renderer scales the captured pixel buffer into the drawable (pixels); the capture
/// may use a different pixels-per-point ratio than the display. The mapping therefore runs
/// in pixels and converts to window points at the end, so fit, fill and native scale
/// all land where the person pointed.
public struct PreviewPointMapping: Equatable, Sendable {
    /// Preview size in points and its backing scale.
    public var viewSize: CGSize
    public var backingScale: CGFloat
    /// Size of the captured image in pixels.
    public var capturePixelSize: CGSize
    /// Size of the source window in points.
    public var windowSize: CGSize
    public var mode: ContentMode

    public init(viewSize: CGSize, backingScale: CGFloat, capturePixelSize: CGSize, windowSize: CGSize, mode: ContentMode) {
        self.viewSize = viewSize
        self.backingScale = backingScale
        self.capturePixelSize = capturePixelSize
        self.windowSize = windowSize
        self.mode = mode
    }

    /// The source-window point (top-left origin, points) under a preview point (top-left
    /// origin, points), or nil over letterbox, cropped-out or degenerate areas.
    public func windowPoint(for viewPoint: CGPoint) -> CGPoint? {
        guard backingScale > 0, capturePixelSize.width > 0, capturePixelSize.height > 0,
              windowSize.width > 0, windowSize.height > 0 else { return nil }
        let transform = ContentTransform(
            sourceRect: CGRect(origin: .zero, size: capturePixelSize),
            destinationRect: CGRect(x: 0, y: 0, width: viewSize.width * backingScale, height: viewSize.height * backingScale),
            mode: mode == .selectedRegion ? .nativeScale : mode)
        guard let pixel = transform.sourcePoint(for: CGPoint(x: viewPoint.x * backingScale, y: viewPoint.y * backingScale))
        else { return nil }
        return CGPoint(x: pixel.x * windowSize.width / capturePixelSize.width,
                       y: pixel.y * windowSize.height / capturePixelSize.height)
    }

    /// Scales a scroll delta from preview points to source points.
    public func windowDelta(for viewDelta: CGSize) -> CGSize {
        guard capturePixelSize.width > 0, capturePixelSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return viewDelta
        }
        let destination = CGSize(width: viewSize.width * backingScale, height: viewSize.height * backingScale)
        let scale: CGFloat
        switch mode {
        case .fit: scale = min(destination.width / capturePixelSize.width, destination.height / capturePixelSize.height)
        case .fill: scale = max(destination.width / capturePixelSize.width, destination.height / capturePixelSize.height)
        case .nativeScale, .selectedRegion: scale = 1
        }
        // view points -> drawable pixels -> capture pixels -> window points
        let factor = backingScale / scale * windowSize.width / capturePixelSize.width
        return CGSize(width: viewDelta.width * factor, height: viewDelta.height * factor)
    }
}

/// What the preview says about interaction for the current source, in plain words.
public enum InteractionLabel {
    public static func text(for support: InteractionSupport, enabled: Bool, trusted: Bool) -> String {
        guard enabled else { return "View only" }
        guard trusted else { return "View only · allow Accessibility for interaction" }
        switch support {
        case .viewOnly: return "View only · no verified input for this app here"
        case .interactive(let kinds):
            let names = [(InputKind.pointerClick, "click"), (.scroll, "scroll"), (.text, "type")]
                .filter { kinds.contains($0.0) }.map(\.1)
            return "Interactive (beta): " + names.joined(separator: ", ")
        }
    }

    public static func text(for refusal: InputRefusal, kind: InputKind) -> String {
        let what = switch kind {
        case .pointerClick: "Click"
        case .scroll: "Scroll"
        case .text: "Typing"
        case .keyShortcut: "Shortcut"
        case .drag: "Drag"
        case .imeComposition: "Input method"
        case .contextMenu: "Right-click"
        }
        let why = switch refusal {
        case .ambiguousTarget: "the window could not be identified exactly"
        case .targetUnreachable: "the window is not reachable right now"
        case .targetChanged: "the window changed"
        case .wrongWindowRisk: "it could reach another window of the app"
        case .notVerified: "not verified for this app here"
        }
        return "\(what) not sent: \(why)"
    }
}
