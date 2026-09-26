import Foundation

/// Byte-exact comparison of two images with possibly different row strides.
///
/// On macOS 27 a window with a standard title bar is delivered as a complete,
/// fully dirty frame at display rate even when nothing in it changed, so
/// ScreenCaptureKit's frame status and dirty rects cannot identify unchanged
/// content. Comparing bytes can, and exits at the first differing row.
public enum FrameComparison {
    public static func identical(_ first: UnsafeRawPointer, rowStride firstStride: Int,
                                 _ second: UnsafeRawPointer, rowStride secondStride: Int,
                                 bytesPerRow: Int, rows: Int) -> Bool {
        guard bytesPerRow <= firstStride, bytesPerRow <= secondStride else { return false }
        for row in 0..<rows where memcmp(first + row * firstStride,
                                         second + row * secondStride, bytesPerRow) != 0 {
            return false
        }
        return true
    }
}
