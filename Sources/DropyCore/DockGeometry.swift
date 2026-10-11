import CoreGraphics
import Foundation

/// Where a docked window and the overlay around it go. All rectangles use AppKit's
/// bottom-left screen coordinates unless a name says global (top-left, as
/// Accessibility and CGWindowList report them).
///
/// The real window hangs below the notch band: macOS keeps every ordinary window
/// below the menu bar, so the band (Dropy's own black outline) fills the space from
/// the top of the screen to the window, and a thin border frames the other sides.
/// Opening from a side edge or a bottom corner, the band only holds the controls and
/// the border reaches the screen edge on the overlay's own side.
public struct DockLayout: Equatable, Sendable {
    /// The overlay's black body: from the screen edge it opens from to around the window.
    public let body: CGRect
    /// The window's frame.
    public let window: CGRect

    public init(body: CGRect, window: CGRect) {
        self.body = body
        self.window = window
    }

    /// The window inside the body, in the body's own coordinates.
    public var windowInBody: CGRect { window.offsetBy(dx: -body.minX, dy: -body.minY) }
    /// The band above the window, where the overlay's own controls are.
    public var band: CGRect { CGRect(x: body.minX, y: window.maxY, width: body.width, height: body.maxY - window.maxY) }
}

public enum DockGeometry {
    /// Border around the window's sides and bottom; the same insets as the preview.
    public static let sideInset = WorkspaceLayout.contentInset
    public static let bottomInset = WorkspaceLayout.bottomInset
    /// A window narrower than this still gets a body wide enough for the notch and
    /// the controls either side of it.
    public static func minimumBodyWidth(notch: CGSize?) -> CGFloat {
        (notch?.width ?? 0) + 2 * (WorkspaceLayout.appSwitcherWidth + WorkspaceLayout.topControlInset + 2)
    }

    /// Height of the band above the window: at least the notch, the menu bar (no
    /// ordinary window can go higher) and the controls. Away from the top edge only
    /// the controls.
    public static func clearance(notch: CGSize?, menuBarHeight: CGFloat, position: OverlayPosition = .notch) -> CGFloat {
        position == .notch ? max(notch?.height ?? 0, menuBarHeight, 32) : controlBand
    }

    /// The band that holds the overlay's controls.
    public static let controlBand: CGFloat = 32

    /// The window size to ask for.
    /// - Parameters:
    ///   - preset: the overlay size; `nativeSize` keeps the window's own size.
    ///   - adaptsToWindow: a window smaller than the preset keeps its size.
    ///   - current: the window's size now.
    ///   - screen: the display's frame.
    public static func windowSize(preset: SizePreset, adaptsToWindow: Bool, current: CGSize,
                                  screen: CGRect, clearance: CGFloat) -> CGSize {
        let largest = CGSize(width: max(1, screen.width - 32 - 2 * sideInset),
                             height: max(1, screen.height - 16 - clearance - bottomInset))
        var size: CGSize
        if preset == .nativeSize {
            size = current
        } else {
            let budget = preset.dimensions
            let fitted = CGSize(width: budget.width - 2 * sideInset, height: budget.height - clearance - bottomInset)
            size = adaptsToWindow
                ? CGSize(width: min(current.width, fitted.width), height: min(current.height, fitted.height))
                : fitted
        }
        return CGSize(width: max(1, min(size.width, largest.width)).rounded(),
                      height: max(1, min(size.height, largest.height)).rounded())
    }

    /// Centers a window of `size` under the notch on `screen`, or places it in a body
    /// at `position` (`visible` is the area between the menu bar and the Dock).
    public static func layout(windowSize size: CGSize, screen: CGRect, clearance: CGFloat,
                              minimumBodyWidth: CGFloat, position: OverlayPosition = .notch,
                              visible: CGRect? = nil) -> DockLayout {
        guard position != .notch else {
            let window = CGRect(x: (screen.midX - size.width / 2).rounded(), y: screen.maxY - clearance - size.height,
                                width: size.width, height: size.height)
            return layout(around: window, screen: screen, minimumBodyWidth: minimumBodyWidth)
        }
        let bodySize = CGSize(width: max(minimumBodyWidth, size.width + 2 * sideInset),
                              height: size.height + clearance + bottomInset)
        let body = position.body(size: bodySize, screen: screen, visible: visible ?? screen)
        let window = CGRect(x: (body.midX - size.width / 2).rounded(), y: body.minY + bottomInset,
                            width: size.width, height: size.height)
        return layout(around: window, screen: screen, minimumBodyWidth: minimumBodyWidth,
                      position: position, clearance: clearance, visible: visible)
    }

    /// The body around wherever the window really is. The window decides: an app can
    /// refuse a size (a minimum or maximum) and macOS can nudge the position, and the
    /// overlay follows rather than fighting it, reaching to its screen edges.
    public static func layout(around window: CGRect, screen: CGRect, minimumBodyWidth: CGFloat,
                              position: OverlayPosition = .notch, clearance: CGFloat = controlBand,
                              visible: CGRect? = nil) -> DockLayout {
        var width = window.width + 2 * sideInset
        var minX = window.minX - sideInset
        if width < minimumBodyWidth {
            minX -= (minimumBodyWidth - width) / 2
            width = minimumBodyWidth
        }
        let minY = window.minY - bottomInset
        let around = CGRect(x: minX, y: minY, width: width, height: window.maxY + clearance - minY)
        return DockLayout(body: position.reachingEdges(around, screen: screen, visible: visible), window: window)
    }

    /// AppKit screen rectangle to global top-left coordinates, given the main display's height.
    public static func globalRect(fromAppKit rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The window's corner radius in points, from the alpha of its snapshot along the
    /// diagonal from the top-left corner (one value per pixel, 0–255). The rounded
    /// corner leaves transparent pixels; where the diagonal first turns opaque is
    /// `r × (1 − 1/√2)` from the corner. Nil when the snapshot has no transparent corner.
    public static func cornerRadius(diagonalAlpha: [UInt8], scale: CGFloat) -> CGFloat? {
        guard scale > 0, let first = diagonalAlpha.firstIndex(where: { $0 >= 128 }), first > 0 else { return nil }
        let radius = CGFloat(first) / (1 - 1 / 2.squareRoot()) / scale
        return min(radius, 40)
    }

    /// Used when the radius cannot be measured; close to macOS 26's window corners.
    public static let defaultCornerRadius: CGFloat = 16
}
