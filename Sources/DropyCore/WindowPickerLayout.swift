import CoreGraphics

/// The chooser has its own reading width, independent of a selected app's size preset.
public enum WindowPickerLayout {
    public static let preferredSize = CGSize(width: 520, height: 560)
    public static let rowHeight: CGFloat = 48
    public static let rowSpacing: CGFloat = 4
    public static func size(available: CGSize) -> CGSize {
        CGSize(width: max(1, min(preferredSize.width, available.width - 32)),
               height: max(1, min(preferredSize.height, available.height - 32)))
    }
}
