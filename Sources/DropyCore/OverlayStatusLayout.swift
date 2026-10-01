import CoreGraphics

/// Shares the actual status field width between layout and native font checks.
public enum OverlayStatusLayout {
    public static func rowWidth(overlayWidth: CGFloat) -> CGFloat { max(100, overlayWidth - 310) }
    public static func interactionWidth(overlayWidth: CGFloat) -> CGFloat { rowWidth(overlayWidth: overlayWidth) * 0.45 }
}
