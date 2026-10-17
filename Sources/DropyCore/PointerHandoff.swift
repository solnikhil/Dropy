import CoreGraphics
import Foundation

/// Live mode's pointer hand-off. The app's windows stay on the Stage, which mirrors the
/// overlay's display one to one: a window at a point on the Stage is shown at the same
/// point of the display, offset by `offset` and never scaled. So the app shows where it
/// really is, menus and popovers included, and the pointer moves between the display and
/// the Stage by that offset alone.
///
/// While the pointer is over anything of the app's (its window in the overlay or a menu,
/// popover or sheet it opened), the real pointer is on the Stage at the matching point, so
/// every hover, click, scroll, menu and drag is the app's own; Dropy draws a cursor where
/// the person sees it. Anywhere else the pointer is on the real display, so the app
/// underneath (a full-screen app) is used as usual. All points are global top-left.
public struct PointerHandoff: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        /// Nothing to do: the pointer is outside the app and stays on the real display.
        case none
        /// Move the pointer onto the Stage here, and show Dropy's cursor at `cursor`.
        case enter(stage: CGPoint, cursor: CGPoint)
        /// The pointer is on the Stage; Dropy's cursor goes here.
        case follow(cursor: CGPoint)
        /// Move the pointer back to the real display here and hide Dropy's cursor.
        case leave(screen: CGPoint)
    }

    /// A point on the Stage minus the same point as the person sees it.
    public var offset: CGVector
    /// What of the app the person sees, in display coordinates: its window in the
    /// overlay and anything it opened beside it.
    public var regions: [CGRect]
    public private(set) var onStage = false

    public init(offset: CGVector, regions: [CGRect]) {
        self.offset = offset
        self.regions = regions
    }

    /// The point on the Stage behind `point` on the display.
    public func stagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
    }

    /// Where the person sees `point` of the Stage.
    public func shownPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - offset.dx, y: point.y - offset.dy)
    }

    public func showsApp(at point: CGPoint) -> Bool {
        regions.contains { $0.contains(point) }
    }

    /// The next step for a pointer that moved to `location`.
    public mutating func pointer(at location: CGPoint) -> Command {
        if onStage {
            let shown = shownPoint(location)
            if showsApp(at: shown) { return .follow(cursor: shown) }
            onStage = false
            return .leave(screen: shown)
        }
        guard showsApp(at: location) else { return .none }
        onStage = true
        return .enter(stage: stagePoint(location), cursor: location)
    }

    /// The pointer was moved away by something else (the overlay closed, a hot key);
    /// it is no longer Dropy's to follow.
    public mutating func reset() { onStage = false }

    /// A window on the Stage, as the window server lists it.
    public struct StageWindow: Equatable, Sendable {
        public var bounds: CGRect
        public var layer: Int
        public var processID: Int32

        public init(bounds: CGRect, layer: Int, processID: Int32) {
            self.bounds = bounds
            self.layer = layer
            self.processID = processID
        }
    }

    /// Window levels on the Stage that are not the app's own surfaces: its menu bar and
    /// the status items in it (macOS draws one per display).
    static let systemLayers: Set<Int> = [Int(CGWindowLevelForKey(.mainMenuWindow)),
                                         Int(CGWindowLevelForKey(.statusWindow))]

    /// The display regions that show the app: its windows on `stage`, and any floating
    /// surface there above ordinary windows (menus, popovers, input-method candidates,
    /// system panels it opens), moved by `offset` and kept inside the Stage's mirror of
    /// the display. Left out: the Stage's desktop and menu bar, Dropy's own windows (its
    /// curtain), and other apps' ordinary windows waiting there to go home. `window` (the
    /// app's window as placed) is always included, before the window server lists it.
    public static func regions(of windows: [StageWindow], window: CGRect, stage: CGRect, offset: CGVector,
                               appProcess: Int32, ownProcess: Int32) -> [CGRect] {
        var regions = [window]
        for row in windows where row.processID != ownProcess && shows(row, appProcess: appProcess) {
            let visible = row.bounds.intersection(stage)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
            let shown = visible.offsetBy(dx: -offset.dx, dy: -offset.dy)
            if !regions.contains(shown) { regions.append(shown) }
        }
        return regions
    }

    /// Whether a window on the Stage is part of what the mirror shows.
    public static func shows(_ row: StageWindow, appProcess: Int32) -> Bool {
        guard row.layer >= 0, !systemLayers.contains(row.layer) else { return false }
        return row.processID == appProcess || row.layer > 0
    }
}
