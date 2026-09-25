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
        case .fit: scale = min(widthRatio, heightRatio)
        case .fill: scale = max(widthRatio, heightRatio)
        case .nativeScale, .selectedRegion: scale = 1
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
