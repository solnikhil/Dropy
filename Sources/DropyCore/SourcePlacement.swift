import CoreGraphics
import Foundation

/// Ways Dropy can try to keep a source window out of sight while previewing it.
/// Each is an M2 experiment until the placement matrix shows it keeps capture alive
/// without leaking UI; none is a product feature yet.
public enum PlacementMode: String, Codable, CaseIterable, Sendable {
    /// Move the window beyond every display.
    case offscreen
    /// Minimize the window to the Dock.
    case minimize
    /// Hide the whole application (all of its windows).
    case hideApp
}

/// The source window facts needed to put it back. Frames use global display
/// coordinates with a top-left origin, as Accessibility and CGWindowList report them.
public struct WindowPlacementState: Codable, Equatable, Sendable {
    public var frame: CGRect
    public var isMinimized: Bool
    public var isAppHidden: Bool

    public init(frame: CGRect, isMinimized: Bool, isAppHidden: Bool) {
        self.frame = frame
        self.isMinimized = isMinimized
        self.isAppHidden = isAppHidden
    }

    /// Frames within this many points are treated as unchanged; AppKit rounds positions.
    public static let frameTolerance: CGFloat = 2

    public func approximatelyEquals(_ other: WindowPlacementState) -> Bool {
        isMinimized == other.isMinimized && isAppHidden == other.isAppHidden &&
            abs(frame.minX - other.frame.minX) <= Self.frameTolerance &&
            abs(frame.minY - other.frame.minY) <= Self.frameTolerance &&
            abs(frame.width - other.frame.width) <= Self.frameTolerance &&
            abs(frame.height - other.frame.height) <= Self.frameTolerance
    }
}

/// A write-ahead record of one placement. It is saved before the window is touched
/// and removed only after the window is restored or can no longer be restored.
public struct PlacementEntry: Codable, Equatable, Sendable {
    public let identity: WindowIdentity
    public let mode: PlacementMode
    public let original: WindowPlacementState
    /// What Dropy expects to observe after placing. A different current state means
    /// someone moved the window since, and that later move wins.
    public var applied: WindowPlacementState
    /// Nil in older records means the placement was already observed.
    /// False means a crash may have interrupted the move or its journal update.
    public var applicationConfirmed: Bool?
    public let createdAt: Date

    public init(identity: WindowIdentity, mode: PlacementMode, original: WindowPlacementState,
                applied: WindowPlacementState, createdAt: Date, applicationConfirmed: Bool? = nil) {
        self.identity = identity
        self.mode = mode
        self.original = original
        self.applied = applied
        self.createdAt = createdAt
        self.applicationConfirmed = applicationConfirmed
    }
}

public enum RestoreDecision: Equatable, Sendable {
    /// Put the window back exactly as it was.
    case restore(WindowPlacementState)
    /// The original display is gone; restore the size on a connected display.
    case restoreOnFallbackDisplay(WindowPlacementState)
    /// The window was moved, restored or shown by someone else since Dropy placed it.
    case keepUserChange
    /// The exact window or process no longer exists; nothing to restore.
    case sourceGone
    /// The write-ahead request was never confirmed; retain it for explicit recovery.
    case pending
}

public enum PlacementRestorer {
    /// Decides how to undo a placement.
    /// - Parameters:
    ///   - current: the window's state now, or nil when the exact window is gone.
    ///   - displays: connected display bounds; the first is the main display.
    public static func decide(_ entry: PlacementEntry, current: WindowPlacementState?,
                              displays: [CGRect]) -> RestoreDecision {
        guard let current else { return .sourceGone }
        if entry.applicationConfirmed == false, current != entry.applied {
            // The system may have clamped the move before a crash. It cannot be
            // distinguished from a later user move, so never discard the record
            // or overwrite that move automatically.
            return current == entry.original ? .keepUserChange : .pending
        }
        guard current == entry.applied else { return .keepUserChange }
        let original = entry.original
        guard !displays.isEmpty,
              PlacementGeometry.visibleFraction(of: original.frame, on: displays) == 0 else {
            return .restore(original)
        }
        var moved = original
        moved.frame = PlacementGeometry.clamp(original.frame, into: displays[0])
        return .restoreOnFallbackDisplay(moved)
    }
}

public enum PlacementGeometry {
    /// Gap between the displays and an off-screen window.
    public static let offscreenGap: CGFloat = 200

    /// A frame of the same size beyond the right-most and lowest display edges.
    /// AppKit clamps foreign moves so part of a window stays reachable; on macOS 27 a
    /// TextEdit window kept 40 pt when pushed sideways and 118 pt when pushed down,
    /// and the bottom-right corner left the smallest strip (40 x 118 pt).
    public static func offscreenFrame(for frame: CGRect, displays: [CGRect]) -> CGRect {
        let right = displays.map(\.maxX).max() ?? frame.maxX
        let bottom = displays.map(\.maxY).max() ?? frame.maxY
        return CGRect(x: right + offscreenGap, y: bottom + offscreenGap,
                      width: frame.width, height: frame.height)
    }

    /// The fraction of `frame` that lies on any display (displays do not overlap).
    public static func visibleFraction(of frame: CGRect, on displays: [CGRect]) -> Double {
        let area = Double(frame.width * frame.height)
        guard area > 0 else { return 0 }
        let visible = displays.reduce(0.0) { total, display in
            let overlap = frame.intersection(display)
            return overlap.isNull ? total : total + Double(overlap.width * overlap.height)
        }
        return min(visible / area, 1)
    }

    /// Keeps the size where it fits and moves the frame fully inside `display`.
    public static func clamp(_ frame: CGRect, into display: CGRect) -> CGRect {
        let width = min(frame.width, display.width)
        let height = min(frame.height, display.height)
        let x = min(max(frame.minX, display.minX), display.maxX - width)
        let y = min(max(frame.minY, display.minY), display.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
