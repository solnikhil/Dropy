import Foundation

/// Turns a series of concealment readings into the two edges the hidden-source rate
/// monitor needs: the moment Dropy's containment starts hiding every pixel of a source,
/// and the moment it stops.
///
/// This exists because the transition, not the reading, is the part that fails silently.
/// The monitor must be told `sourceHidden` exactly once per concealment, must be told
/// `sourceShown` when the concealment ends for any reason (a restore, an uncovered tab,
/// a new selection, a closed overlay), and must never be armed for a window that is not
/// being drawn at all — a minimized window delivers no frames for a reason that has
/// nothing to do with its app throttling anything, so calling that "slowed" would be a
/// false claim, and one that no rate measurement could contradict afterwards. Keeping it
/// in `DropyCore` puts every one of those events under unit test instead of leaving them
/// to the order of statements in a view controller.
public struct HiddenSourceWatch: Equatable, Sendable {
    /// Whether the rate monitor is currently armed: Dropy's containment hides every
    /// pixel of the source and the window server still draws it.
    public private(set) var hidden: Bool

    public init(hidden: Bool = false) {
        self.hidden = hidden
    }

    /// A fresh concealment reading.
    ///
    /// - Parameters:
    ///   - concealment: what Dropy's containment does to the source now, or nil when
    ///     there is no source to read (no selection yet, or the read failed).
    ///   - capturing: whether a stream is running. A verdict about a hidden source is
    ///     only meaningful while frames are arriving, so this ends the watch as surely
    ///     as a visible window does.
    /// - Returns: the value to pass to the rate monitor — true for "the source became
    ///   hidden", false for "it is no longer hidden" — or nil when nothing changed and
    ///   the monitor must not be touched. Re-arming a monitor that is already armed
    ///   would move its baseline to the current, already-throttled rate.
    public mutating func update(concealment: SourceConcealment?, capturing: Bool) -> Bool? {
        // Only `.hidden` arms the watch. `.notRendering` is the case that must not:
        // "not visible" and "not being drawn" look alike from the outside and differ
        // entirely in what a frame rate means.
        let next = capturing && concealment == .hidden
        guard next != hidden else { return nil }
        hidden = next
        return next
    }

    /// Forget the concealment entirely: a closed overlay, a new selection and a new
    /// stream all start without one. Returns what the monitor must be told, or nil when
    /// it was not armed. The monitor is told rather than relied upon to be discarded at
    /// the same moment: a hidden verdict must not outlive the concealment that justified
    /// it even if the old stream is still around.
    public mutating func reset() -> Bool? {
        guard hidden else { return nil }
        hidden = false
        return false
    }

    /// Whether the once-a-second re-read loop should be running. It exists only for a
    /// hidden source: the rate needs a measuring window of frames before it means
    /// anything, and an uncovered tab or a restore must be noticed promptly. Anything
    /// else is idle, so nothing polls while the preview shows a visible window.
    public var runsLoop: Bool { hidden }
}
