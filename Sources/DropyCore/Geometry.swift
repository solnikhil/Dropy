import Foundation
import CoreGraphics

public enum OverlayGeometry {
    /// AppKit screen coordinates are bottom-origin. The overlay stays flush with the screen top.
    public static func frame(on screen: CGRect, preferredSize: CGSize) -> CGRect {
        let width = min(max(preferredSize.width, 320), screen.width)
        let height = min(max(preferredSize.height, 180), screen.height)
        return CGRect(x: screen.midX - width / 2,
                      y: screen.maxY - height,
                      width: width,
                      height: height)
    }

    public static func notchTrigger(on screen: CGRect, notchWidth: CGFloat,
                                    bandHeight: CGFloat) -> CGRect {
        let width = min(max(notchWidth, 96), screen.width)
        let height = min(max(bandHeight, 24), screen.height)
        return CGRect(x: screen.midX - width / 2,
                      y: screen.maxY - height,
                      width: width,
                      height: height)
    }
}

/// Maps an interaction in the displayed viewport back to the source image.
/// Coordinates are top-left-origin pixels/points inside each respective rectangle.
public struct ContentTransform: Sendable {
    public let sourceRect: CGRect
    public let destinationRect: CGRect
    public let mode: ContentMode

    public init(sourceRect: CGRect, destinationRect: CGRect, mode: ContentMode) {
        self.sourceRect = sourceRect
        self.destinationRect = destinationRect
        self.mode = mode
    }

    public func sourcePoint(for destinationPoint: CGPoint) -> CGPoint? {
        guard sourceRect.width > 0, sourceRect.height > 0,
              destinationRect.width > 0, destinationRect.height > 0,
              destinationRect.contains(destinationPoint) else { return nil }

        let widthRatio = destinationRect.width / sourceRect.width
        let heightRatio = destinationRect.height / sourceRect.height
        let scale: CGFloat
        switch mode {
        // A selected region is cropped by the capture, so what arrives here is already
        // just the region; it is letterboxed into the viewport exactly like fit.
        case .fit, .selectedRegion: scale = min(widthRatio, heightRatio)
        case .fill: scale = max(widthRatio, heightRatio)
        case .nativeScale: scale = 1
        }

        let imageWidth = sourceRect.width * scale
        let imageHeight = sourceRect.height * scale
        let imageX = destinationRect.midX - imageWidth / 2
        let imageY = destinationRect.midY - imageHeight / 2
        let mapped = CGPoint(x: sourceRect.minX + (destinationPoint.x - imageX) / scale,
                             y: sourceRect.minY + (destinationPoint.y - imageY) / scale)
        return sourceRect.contains(mapped) ? mapped : nil
    }
}

// MARK: Region selection (M4)

/// A rectangle inside a source window, stored as fractions of that window's size with a
/// top-left origin.
///
/// Normalized coordinates are what a preference can outlive a session with: the same
/// stored value still names the same part of the window after the window is moved,
/// resized, or captured at another scale. Every value is validated on the way in and on
/// the way out of storage, so a hand-edited or truncated preference cannot produce a crop
/// that falls outside the window.
public struct NormalizedRegion: Codable, Equatable, Sendable {
    /// Distance from the window's left edge, as a fraction of its width.
    public let x: Double
    /// Distance from the window's top edge, as a fraction of its height.
    public let y: Double
    public let width: Double
    public let height: Double

    /// A region must cover at least this fraction of each side. Anything smaller is
    /// almost always an accidental flick of the pointer rather than a choice, and it
    /// magnifies a handful of captured pixels into the whole preview.
    public static let minimumSide: Double = 0.02
    /// Slack for the rounding that a drag in view points accumulates on its way to
    /// fractions of a window.
    private static let tolerance: Double = 1e-9

    /// Fails rather than clamping silently for a region that is degenerate, inverted,
    /// not finite, or reaches outside the window.
    public init?(x: Double, y: Double, width: Double, height: Double) {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width >= Self.minimumSide, height >= Self.minimumSide,
              x >= -Self.tolerance, y >= -Self.tolerance,
              x + width <= 1 + Self.tolerance, y + height <= 1 + Self.tolerance else { return nil }
        let left = min(max(x, 0), 1)
        let top = min(max(y, 0), 1)
        self.x = left
        self.y = top
        self.width = min(width, 1 - left)
        self.height = min(height, 1 - top)
    }

    public init?(rect: CGRect) {
        self.init(x: Double(rect.minX), y: Double(rect.minY),
                  width: Double(rect.width), height: Double(rect.height))
    }

    /// The region as a unit rectangle (top-left origin).
    public var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// The region in source-window points, with a top-left origin inside the window.
    /// Nil when the window is too small for the region to name at least one point.
    public func sourceRect(inWindowOfSize size: CGSize) -> CGRect? {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        let rect = CGRect(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height,
                          width: CGFloat(width) * size.width, height: CGFloat(height) * size.height)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return rect
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }

    /// A stored region that no longer satisfies the invariants is an error, not a value to
    /// repair by guesswork: callers decide whether to drop it or to refuse the whole record.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = Self(x: try container.decode(Double.self, forKey: .x),
                          y: try container.decode(Double.self, forKey: .y),
                          width: try container.decode(Double.self, forKey: .width),
                          height: try container.decode(Double.self, forKey: .height))
        guard let stored else {
            throw DecodingError.dataCorruptedError(
                forKey: .width, in: container,
                debugDescription: "a stored region must be inside the window and at least \(Self.minimumSide) of each side")
        }
        self = stored
    }
}

/// What ScreenCaptureKit is asked for when a region is selected: the crop and the output
/// surface it should be scaled into.
public struct RegionCrop: Equatable, Sendable {
    /// Logical source area in window points. This is applied by the Metal renderer;
    /// ScreenCaptureKit ignores sourceRect for single-window filters.
    public let sourceRect: CGRect
    /// Whole pixels the configuration should request for the cropped output.
    public let pixelSize: CGSize

    public init(sourceRect: CGRect, pixelSize: CGSize) {
        self.sourceRect = sourceRect
        self.pixelSize = pixelSize
    }
}

/// Turns a drag over the preview into a stored region, and a stored region into the crop
/// the capture is configured with. Both directions are pure so they can be tested without
/// a window, a stream or a display.
public enum RegionSelection {
    /// Smallest cropped output worth asking for, in pixels per side; matches the floor the
    /// uncropped configuration uses.
    public static let minimumCropPixelSide: CGFloat = 64
    /// Capture never asks for more pixels per source point than the display can show, and
    /// never collapses a crop below this ratio.
    public static let minimumCaptureScale: CGFloat = 0.1

    /// Where the captured image is actually drawn inside the preview, in view points with
    /// a top-left origin. Everything outside it is letterbox: it shows no source content,
    /// so it can neither be clicked nor selected.
    public static func imageRect(in viewSize: CGSize, capturePixelSize: CGSize,
                                 backingScale: CGFloat, mode: ContentMode) -> CGRect? {
        guard [viewSize.width, viewSize.height, backingScale, capturePixelSize.width, capturePixelSize.height].allSatisfy({ $0.isFinite }),
              viewSize.width > 0, viewSize.height > 0, backingScale > 0,
              capturePixelSize.width > 0, capturePixelSize.height > 0 else { return nil }
        let widthRatio = viewSize.width * backingScale / capturePixelSize.width
        let heightRatio = viewSize.height * backingScale / capturePixelSize.height
        let scale: CGFloat
        switch mode {
        case .fit, .selectedRegion: scale = min(widthRatio, heightRatio)
        case .fill: scale = max(widthRatio, heightRatio)
        case .nativeScale: scale = 1
        }
        let width = capturePixelSize.width * scale / backingScale
        let height = capturePixelSize.height * scale / backingScale
        return CGRect(x: (viewSize.width - width) / 2, y: (viewSize.height - height) / 2,
                      width: width, height: height)
    }

    /// The region a drag selects, in source-window coordinates.
    ///
    /// The caller must be showing the whole, uncropped source window letterboxed into the
    /// preview (Dropy drops any active crop while a region is being selected). That way the
    /// drawn image is the window, and a fraction of the image is the same fraction of the
    /// window — no crop has to be composed with another crop.
    ///
    /// A drag that starts or ends over the letterbox is clipped to the image rather than
    /// refused, because the intent is unambiguous. A drag entirely outside the image, or one
    /// too small to be a deliberate choice, selects nothing.
    public static func regionInWindow(fromDrag start: CGPoint, to end: CGPoint, in viewSize: CGSize,
                                      capturePixelSize: CGSize, backingScale: CGFloat) -> NormalizedRegion? {
        guard let image = imageRect(in: viewSize, capturePixelSize: capturePixelSize,
                                   backingScale: backingScale, mode: .fit),
              image.width > 0, image.height > 0 else { return nil }
        let drag = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        let inside = drag.intersection(image)
        guard !inside.isNull, !inside.isEmpty else { return nil }
        return NormalizedRegion(x: Double((inside.minX - image.minX) / image.width),
                                y: Double((inside.minY - image.minY) / image.height),
                                width: Double(inside.width / image.width),
                                height: Double(inside.height / image.height))
    }

    /// The crop and output size for a stored region, or nil when the region cannot be
    /// captured (a window or preview too small to carry it), in which case the caller must
    /// fall back to capturing the whole window rather than guessing a rectangle.
    ///
    /// The crop is captured to fit the preview: asking for more pixels than the preview can
    /// draw spends capture bandwidth on detail that is scaled away again.
    public static func crop(region: NormalizedRegion, windowSize: CGSize, previewSize: CGSize,
                            backingScale: CGFloat) -> RegionCrop? {
        guard backingScale > 0, previewSize.width > 0, previewSize.height > 0,
              let sourceRect = region.sourceRect(inWindowOfSize: windowSize) else { return nil }
        let horizontal = previewSize.width * backingScale / sourceRect.width
        let vertical = previewSize.height * backingScale / sourceRect.height
        let scale = min(max(min(horizontal, vertical), minimumCaptureScale), backingScale)
        let width = max(minimumCropPixelSide, (sourceRect.width * scale).rounded())
        let height = max(minimumCropPixelSide, (sourceRect.height * scale).rounded())
        return RegionCrop(sourceRect: sourceRect, pixelSize: CGSize(width: width, height: height))
    }
}


extension RegionSelection {
    /// A single-window filter captures the whole surface. Size it so the selected
    /// subtexture has the requested resolution without exceeding native pixel density.
    public static func fullSurface(region: NormalizedRegion, plan: RegionCrop,
                                   windowSize: CGSize, backingScale: CGFloat) -> CGSize {
        let scale = min(plan.pixelSize.width / plan.sourceRect.width,
                        plan.pixelSize.height / plan.sourceRect.height, backingScale)
        return CGSize(width: max(64, (windowSize.width * scale).rounded(.up)),
                      height: max(64, (windowSize.height * scale).rounded(.up)))
    }
}
