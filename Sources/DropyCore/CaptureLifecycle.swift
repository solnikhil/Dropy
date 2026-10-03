import Foundation

/// Why a capture cannot continue. Each case needs a different recovery, so they
/// are never collapsed into one generic error.
public enum CaptureFailure: Equatable, Sendable {
    /// Screen Recording is denied or was revoked for Dropy.
    case permissionDenied
    /// The selected window no longer exists; its app is still running.
    case sourceWindowClosed(applicationName: String)
    /// The selected window's process exited. A relaunch is a different process.
    case targetQuit(applicationName: String)
    /// The person ended capture from the system's screen-sharing controls.
    case stoppedFromSystemControls
    /// The stream stopped for another reason and did not recover.
    case streamInterrupted(code: Int)
    /// The window list could not be read.
    case windowListUnavailable(code: Int)

    public var message: String {
        switch self {
        case .permissionDenied:
            "Screen Recording is off for Dropy. Allow it in System Settings, then choose a window again."
        case .sourceWindowClosed(let app):
            "The selected \(app) window closed. Choose another window."
        case .targetQuit(let app):
            "\(app) quit. Relaunch it, then choose a window."
        case .stoppedFromSystemControls:
            "Capture was stopped from the system controls. Choose a window to start again."
        case .streamInterrupted(let code):
            "Capture was interrupted (code \(code)). Choose the window again to retry."
        case .windowListUnavailable(let code):
            "Window list unavailable (code \(code)). Open the window menu to retry."
        }
    }

    /// A log-safe name: no app names, window titles or captured content.
    public var diagnosticName: String {
        switch self {
        case .permissionDenied: "permissionDenied"
        case .sourceWindowClosed: "sourceWindowClosed"
        case .targetQuit: "targetQuit"
        case .stoppedFromSystemControls: "stoppedFromSystemControls"
        case .streamInterrupted(let code): "streamInterrupted(\(code))"
        case .windowListUnavailable(let code): "windowListUnavailable(\(code))"
        }
    }

    /// Only a permission failure can be fixed in System Settings.
    public var opensPrivacySettings: Bool { self == .permissionDenied }
}

/// Visibility facts must not conflate another display with a hidden/minimized app.
public enum SourceVisibility: Equatable, Sendable {
    case available
    case hidden
    case notReportedOnScreen
    case unknown

    public static func resolve(appHidden: Bool, serverOnScreen: Bool?, captureOnScreen: Bool) -> SourceVisibility {
        if appHidden { return .hidden }
        if let serverOnScreen { return serverOnScreen ? .available : .notReportedOnScreen }
        return captureOnScreen ? .available : .unknown
    }
    public func message(applicationName app: String) -> String {
        switch self {
        case .available: return ""
        case .hidden: return "\(app) is hidden"
        case .notReportedOnScreen: return "\(app) window is not reported on the active desktop"
        case .unknown: return "\(app) window visibility could not be confirmed"
        }
    }
}

/// Overlay lifecycle. A failure keeps its reason until the person makes a new choice.
public enum CapturePhase: Equatable, Sendable {
    case closed
    case selecting
    case starting(applicationName: String)
    case viewing
    /// The window exists but is minimized, hidden or on another Space, so
    /// ScreenCaptureKit is not delivering new frames.
    case paused(applicationName: String)
    case sourceVisibility(applicationName: String, visibility: SourceVisibility)
    case failed(CaptureFailure)

    /// A stream is starting or running for the current selection.
    public var isCapturing: Bool {
        switch self {
        case .starting, .viewing, .paused, .sourceVisibility: true
        default: false
        }
    }

    public var failure: CaptureFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    /// A log-safe name: no app names, window titles or captured content.
    public var diagnosticName: String {
        switch self {
        case .closed: "closed"
        case .selecting: "selecting"
        case .starting: "starting"
        case .viewing: "viewing"
        case .paused: "paused"
        case .sourceVisibility: "sourceVisibility"
        case .failed(let failure): "failed.\(failure.diagnosticName)"
        }
    }

    public var message: String? {
        switch self {
        case .closed, .selecting: nil
        case .starting(let app): "Starting preview: \(app)…"
        case .viewing: "Live preview · interaction bridge not enabled yet"
        case .paused(let app):
            "Waiting for captured frames from \(app)"
        case .sourceVisibility(let app, let visibility):
            visibility.message(applicationName: app)
        case .failed(let failure): failure.message
        }
    }
}

/// How a stream error should be handled, derived only from its domain and code.
public enum CaptureErrorKind: Equatable, Sendable {
    case permissionDenied
    case stoppedFromSystemControls
    case windowListUnavailable
    /// The content went away; the caller re-resolves the window to tell a
    /// closed window from a quit app.
    case sourceMissing
    case interrupted

    public static let streamErrorDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"

    // SCStreamError.Code raw values, kept here so classification stays testable
    // without ScreenCaptureKit.
    static let userDeclined = -3801
    static let applicationConnectionInvalid = -3804
    static let applicationConnectionInterrupted = -3805
    static let noMatchingApplicationContext = -3806
    static let noWindowList = -3813
    static let noCaptureSource = -3815
    static let userStopped = -3817

    public static func classify(domain: String, code: Int) -> CaptureErrorKind {
        guard domain == streamErrorDomain else { return .interrupted }
        switch code {
        case userDeclined: return .permissionDenied
        case userStopped: return .stoppedFromSystemControls
        case noWindowList: return .windowListUnavailable
        case applicationConnectionInvalid, applicationConnectionInterrupted,
             noMatchingApplicationContext, noCaptureSource:
            return .sourceMissing
        default: return .interrupted
        }
    }
}
