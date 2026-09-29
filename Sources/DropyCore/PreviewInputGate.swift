import CoreGraphics
import Foundation

/// The capture geometry one presented frame was produced with: which window the stream
/// showed, the window size (points) its configuration was built for, and the output
/// size (pixels) that configuration asked for.
public struct CaptureGeometry: Equatable, Sendable {
    public var windowID: UInt32
    public var windowSize: CGSize
    public var pixelSize: CGSize

    public init(windowID: UInt32, windowSize: CGSize, pixelSize: CGSize) {
        self.windowID = windowID
        self.windowSize = windowSize
        self.pixelSize = pixelSize
    }
}

/// The frame on screen in the preview, as the renderer saw it.
public struct PresentedFrame: Equatable, Sendable {
    /// Pixel size of the buffer actually drawn.
    public var pixelSize: CGSize
    /// The stream geometry attached when the frame was forwarded; nil if unknown.
    public var geometry: CaptureGeometry?

    public init(pixelSize: CGSize, geometry: CaptureGeometry?) {
        self.pixelSize = pixelSize
        self.geometry = geometry
    }
}

/// Decides, before any mapping, whether a point in the preview can be tied to the
/// selected source window with certainty (M3 routing gate).
///
/// A preview point only means something for the exact frame that was drawn. Input is
/// refused whenever the handler belongs to an older selection, no frame is drawn, the
/// frame came from another window, or the frame's geometry does not match the source's
/// current size, as during a resize before the stream has caught up.
public enum PreviewInputGate {
    public enum Refusal: Error, Equatable, Sendable {
        /// The handler was installed for a different selection than the current one.
        case sourceChanged
        /// Nothing is drawn yet (starting, switching, cleared).
        case noFrame
        /// The drawn frame came from another window, e.g. a late frame after a switch.
        case frameFromOtherWindow
        /// The drawn frame's geometry is stale or unknown; the source is being resized.
        case geometryChanging
    }

    /// Sizes within this many points are the same window size (rounding between the
    /// window server and Accessibility).
    public static let sizeTolerance: CGFloat = 1

    public static func sizesMatch(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= sizeTolerance && abs(a.height - b.height) <= sizeTolerance
    }

    /// The window size (points) to map through, when the drawn frame is certainly the
    /// selected window at its current size.
    public static func check(handler: WindowIdentity, selected: WindowIdentity?, frame: PresentedFrame?,
                             sourceWindowSize: CGSize?) -> Result<CGSize, Refusal> {
        guard let selected, selected == handler else { return .failure(.sourceChanged) }
        guard let frame, frame.pixelSize.width > 0, frame.pixelSize.height > 0 else { return .failure(.noFrame) }
        guard let geometry = frame.geometry else { return .failure(.geometryChanging) }
        guard geometry.windowID == handler.windowID else { return .failure(.frameFromOtherWindow) }
        // A frame from before a reconfiguration has the old output size.
        guard frame.pixelSize == geometry.pixelSize else { return .failure(.geometryChanging) }
        guard let sourceWindowSize, sizesMatch(sourceWindowSize, geometry.windowSize) else {
            return .failure(.geometryChanging)
        }
        return .success(geometry.windowSize)
    }
}
