import CoreGraphics
import Foundation

/// Which `SourceCondition` a source window is in, decided from facts the app layer reads
/// once per send. The evidence in `InputEvidence.json` is recorded per condition, so a
/// wrong condition reads the wrong evidence: reporting a covered source as `visible`
/// would send input a covered trial never verified. The ordering and the coverage test
/// therefore live here, with unit tests, instead of in the router.

/// One window the window server reports on screen above the source, as read from
/// `CGWindowListCopyWindowInfo` with `.optionOnScreenAboveWindow`.
public struct WindowAboveSource: Equatable, Sendable {
    /// `kCGWindowOwnerPID`: the process that owns the window.
    public var ownerProcessID: Int32
    /// `kCGWindowBounds`: global bounds with a top-left origin.
    public var bounds: CGRect
    /// `kCGWindowAlpha`: 0 for a window that draws nothing.
    public var alpha: Double

    public init(ownerProcessID: Int32, bounds: CGRect, alpha: Double) {
        self.ownerProcessID = ownerProcessID
        self.bounds = bounds
        self.alpha = alpha
    }
}

/// Whether another app's window is drawn over the source where the input aims.
public enum SourceCoverage: Equatable, Sendable {
    case uncovered
    case covered
    /// The window list could not be read, so neither answer is proven. Nothing may be
    /// sent on the assumption that the source is visible.
    case unknown
}

public enum SourceCoverageRule {
    /// A window at least this opaque can hide what is behind it; below it, nothing is drawn.
    public static let minimumOpaqueAlpha = 0.01

    /// Whether anything is drawn over the source at `point` (global, top-left origin).
    ///
    /// `windowsAbove` is nil when the list could not be read, which is `unknown`, never
    /// `uncovered`.
    ///
    /// Dropy's own windows do not cover a source, because no shipped trial was recorded
    /// with one above it and Dropy's windows are above the source by construction:
    /// `Scripts/bench/InputProbe` stages `covered` by raising the source app's own second
    /// window exactly over the source while Dropy is not running, and the parked evidence
    /// was recorded with the window beyond the displays, which Dropy then covers with a
    /// parking tab. Counting Dropy's own overlay or tabs would relabel every end-to-end
    /// verified `visible` and `parked` run as a condition that was never tested. Any other
    /// process's window above the point still reads as `covered`.
    public static func coverage(at point: CGPoint, windowsAbove: [WindowAboveSource]?,
                               ownProcessID: Int32) -> SourceCoverage {
        guard point.x.isFinite, point.y.isFinite, let windowsAbove,
              windowsAbove.allSatisfy({ window in
                  window.alpha.isFinite && [window.bounds.minX, window.bounds.minY,
                      window.bounds.width, window.bounds.height].allSatisfy(\.isFinite)
              }) else { return .unknown }
        let covering = windowsAbove.contains { window in
            window.ownerProcessID != ownProcessID
                && window.alpha >= minimumOpaqueAlpha
                && window.bounds.width > 0 && window.bounds.height > 0
                && window.bounds.contains(point)
        }
        return covering ? .covered : .uncovered
    }
}

/// What Dropy observed about one source window, each field read from the system by the
/// app layer just before a send.
public struct SourceObservation: Equatable, Sendable {
    /// The owning application is hidden (all of its windows).
    public var applicationIsHidden: Bool
    /// The exact window reports itself minimized.
    public var isMinimized: Bool
    /// The Spaces the window is on, and the active Spaces; nil when either is unreadable.
    public var windowSpaces: [UInt64]?
    public var activeSpaces: [UInt64]?
    /// Dropy's placement journal holds a placement for this window that moves it.
    public var parkedByDropy: Bool
    /// The fraction of the window the window server reports on a display; nil when the
    /// window server does not list the window.
    public var visibleFraction: Double?
    public var coverage: SourceCoverage

    public init(applicationIsHidden: Bool, isMinimized: Bool, windowSpaces: [UInt64]?, activeSpaces: [UInt64]?,
                parkedByDropy: Bool, visibleFraction: Double?, coverage: SourceCoverage) {
        self.applicationIsHidden = applicationIsHidden
        self.isMinimized = isMinimized
        self.windowSpaces = windowSpaces
        self.activeSpaces = activeSpaces
        self.parkedByDropy = parkedByDropy
        self.visibleFraction = visibleFraction
        self.coverage = coverage
    }
}

public enum SourceConditionRule {
    /// Less of the window than this on any display is the same situation as parked:
    /// someone else moved it beyond the displays.
    public static let parkedVisibleFraction = 0.5

    /// The condition whose evidence applies, or nil when it cannot be determined (an
    /// unreadable window list); a send is then refused rather than guessed.
    ///
    /// Order matters and is from the most specific state outwards: a hidden app has no
    /// on-screen window at all, a minimized or other-Space window is not composited where
    /// the preview points, and a window Dropy parked is off the displays behind Dropy's
    /// own tab, which is its own verified condition. Coverage is the last question, asked
    /// only about a window that is otherwise on screen and on this Space.
    public static func condition(_ observation: SourceObservation) -> SourceCondition? {
        if observation.applicationIsHidden { return .hidden }
        if observation.isMinimized { return .minimized }
        guard let spaces = observation.windowSpaces, let active = observation.activeSpaces,
              !spaces.isEmpty, !active.isEmpty else { return nil }
        if Set(spaces).isDisjoint(with: active) { return .otherSpace }
        if observation.parkedByDropy { return .parked }
        // Moved beyond every display by someone else: the same situation as parked.
        guard let fraction = observation.visibleFraction, fraction.isFinite,
              fraction >= 0, fraction <= 1 else { return nil }
        if fraction < parkedVisibleFraction { return .parked }
        switch observation.coverage {
        case .covered: return .covered
        case .uncovered: return .visible
        case .unknown: return nil
        }
    }
}
