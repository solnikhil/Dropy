import CoreGraphics

/// Fits the measured source within the chosen size budget. Small sources retain
/// native point size; large sources scale down proportionally. Expand uses the display.
public struct WorkspaceLayout: Equatable, Sendable {
    public static let appSwitcherWidth: CGFloat = 40
    public static let topControlInset: CGFloat = 10
    public static let contentInset: CGFloat = 8
    public static let bottomInset: CGFloat = 8
    private static let housingControlGap: CGFloat = 2
    public let size: CGSize
    public let preview: CGRect
    public init(size: CGSize, preview: CGRect) { self.size = size; self.preview = preview }
    public static func preview(in size: CGSize, notch: CGSize) -> CGRect {
        CGRect(x: contentInset, y: bottomInset, width: max(1, size.width - 2 * contentInset),
               height: max(1, size.height - max(notch.height, 32) - bottomInset))
    }
    public static func make(source: CGSize, screen: CGSize, notch: CGSize, expanded: Bool,
                            maximumSize: CGSize? = nil) -> WorkspaceLayout {
        let clearance = max(notch.height, 32)
        let budget = expanded ? screen : maximumSize ?? screen
        let widthLimit = max(1, min(screen.width - 32, budget.width))
        let totalHeightLimit = max(1, min(screen.height - 32, budget.height))
        let heightLimit = max(1, totalHeightLimit - clearance - bottomInset)
        let sourceWidth = max(1, source.width), sourceHeight = max(1, source.height)
        let fit = min(max(1, widthLimit - 2 * contentInset) / sourceWidth, heightLimit / sourceHeight)
        let scale = max(0.001, expanded ? fit : min(1, fit))
        let image = CGSize(width: sourceWidth * scale, height: sourceHeight * scale)
        let controls = 2 * (appSwitcherWidth + topControlInset + housingControlGap)
        let width = min(widthLimit, max(notch.width + controls, image.width + 2 * contentInset))
        let size = CGSize(width: width, height: image.height + clearance + bottomInset)
        return WorkspaceLayout(size: size, preview: preview(in: size, notch: notch))
    }
}
