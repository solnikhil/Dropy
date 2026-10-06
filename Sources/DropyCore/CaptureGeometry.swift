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
