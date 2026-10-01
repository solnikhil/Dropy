import CoreGraphics
import Foundation

/// Whether Dropy's own containment leaves any pixel of a source window on screen.
///
/// This is the question the hidden-source rate monitor needs answered before it may
/// compare frame rates: only a window that Dropy hid, and that the system still draws,
/// can be judged "slowed while hidden". A window nobody draws delivers no frames for a
/// reason that has nothing to do with the app throttling it.
public enum SourceConcealment: String, Equatable, Sendable {
    /// Dropy's placement leaves no pixel of the window on screen while the window
    /// server still composites it, so its app is expected to keep drawing it.
    case hidden
    /// At least one pixel of the source is on screen, or Dropy placed nothing.
    case visible
    /// The window is not being drawn at all: minimized, its app hidden, or absent from
    /// the window server. The preview already reports this as a paused source.
    case notRendering
}

/// What Dropy can observe about its own containment of one source window. Frames are
/// global display coordinates with a top-left origin, as Accessibility, CGWindowList
/// and CGDisplayBounds report them.
public struct SourceContainment: Equatable, Sendable {
    /// The placement Dropy applied and has not undone, or nil when Dropy placed nothing.
    public var mode: PlacementMode?
    /// The window server's bounds for the exact window, or nil when it lists no such window.
    public var bounds: CGRect?
    /// The window server's on-screen flag for that window.
    public var isOnScreen: Bool
    /// Connected display bounds.
    public var displays: [CGRect]
    /// What Dropy's own parking tabs cover.
    public var covered: [CGRect]

    public init(mode: PlacementMode? = nil, bounds: CGRect? = nil, isOnScreen: Bool = false,
                displays: [CGRect] = [], covered: [CGRect] = []) {
        self.mode = mode
        self.bounds = bounds
        self.isOnScreen = isOnScreen
        self.displays = displays
        self.covered = covered
    }

    public var concealment: SourceConcealment {
        // Dropy claims nothing about a window it did not place: another app's window in
        // front of it, or a Space switch, is not Dropy's containment.
        guard let mode else { return .visible }
        // Minimizing a window or hiding its app stops the drawing itself.
        guard mode.movesWindow else { return .notRendering }
        // A window the window server does not list cannot be measured either.
        guard let bounds else { return .notRendering }
        // Without a display list there are no facts to decide on, as for a restore.
        guard !displays.isEmpty else { return .notRendering }
        let tolerance = PlacementGeometry.concealmentTolerance
        // A frame beyond every display is hidden by the move alone, and the window
        // server reports exactly such a window as off screen. Measured on 2026-09-30:
        // AppKit clamps a foreign move so a strip stays, so this is the rarer case.
        // `isOnScreen` carries no information for such a window — a minimize reports the
        // same off-screen flag as the move does — so a window minimized after being
        // moved off every display still reads `.hidden`. What keeps that from being
        // called slowed is the rate's own requirement of an animating baseline, not this
        // decision; see `SourceConcealmentTests`.
        guard PlacementGeometry.visibleArea(of: bounds, on: displays) > tolerance else { return .hidden }
        // Part of the frame is over a display, so only Dropy's tabs can hide it — and
        // only a composited window is being drawn. Off screen here means the window was
        // minimized or its app hidden after Dropy moved it, whatever Dropy asked for.
        guard isOnScreen else { return .notRendering }
        return PlacementGeometry.uncoveredArea(of: bounds, on: displays, covered: covered) > tolerance
            ? .visible : .hidden
    }
}
