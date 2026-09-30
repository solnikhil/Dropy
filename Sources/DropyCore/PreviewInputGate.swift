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
    /// ScreenCaptureKit expresses contentRect in scaled surface points. Dividing by
    /// contentScale recovers source points; scaleFactor converts the rect to pixels.
    /// Mapping currently requires content to occupy the full surface (no crop/padding).
    public static func measured(windowID: UInt32, pixelSize: CGSize, contentRect: CGRect?,
                                contentScale: CGFloat?, scaleFactor: CGFloat?) -> CaptureGeometry? {
        guard let rect = contentRect, let scale = contentScale, let density = scaleFactor,
              scale.isFinite, density.isFinite, scale > 0, density > 0,
              rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0,
              abs(rect.minX * density) <= 2, abs(rect.minY * density) <= 2,
              abs(rect.width * density - pixelSize.width) <= 2,
              abs(rect.height * density - pixelSize.height) <= 2 else { return nil }
        return CaptureGeometry(windowID: windowID,
                               windowSize: CGSize(width: rect.width / scale, height: rect.height / scale),
                               pixelSize: pixelSize)
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
        /// A hand-off has given the real window the person's input; the preview sends none.
        case handOffActive
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
                             sourceWindowSize: CGSize?, handOffActive: Bool = false) -> Result<CGSize, Refusal> {
        // The real window has the person's keyboard and pointer; sending a second copy
        // of their input from the preview would duplicate or contradict it.
        guard !handOffActive else { return .failure(.handOffActive) }
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
