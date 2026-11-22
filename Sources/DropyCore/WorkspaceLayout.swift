import CoreGraphics

/// Fits the measured source within the chosen size budget. Small sources retain
/// native point size; large sources scale down proportionally. Expand uses the display.
public struct WorkspaceLayout: Equatable, Sendable {
    public static let appSwitcherWidth: CGFloat = 40
    public static let trailingControlsWidth: CGFloat = 60
    public static let controlWingWidth: CGFloat = max(appSwitcherWidth, trailingControlsWidth)
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
        let budget = expanded ? screen : maximumSize ?? screen
        let widthLimit = max(1, min(screen.width - 32, budget.width))
        let totalHeightLimit = max(1, min(screen.height - 32, budget.height))
        // When display space is smaller than the normal chrome, shrink the
        // insets before fitting content so the final body still obeys its budget.
        let clearance = min(max(notch.height, 32), max(0, totalHeightLimit - 1))
        let bottom = min(bottomInset, max(0, totalHeightLimit - clearance - 1))
        let horizontal = min(contentInset, max(0, (widthLimit - 1) / 2))
        let heightLimit = totalHeightLimit - clearance - bottom
        let sourceWidth = max(1, source.width), sourceHeight = max(1, source.height)
        let fit = min((widthLimit - 2 * horizontal) / sourceWidth, heightLimit / sourceHeight)
        let scale = expanded ? fit : min(1, fit)
        let image = CGSize(width: sourceWidth * scale, height: sourceHeight * scale)
        let controls = 2 * (controlWingWidth + topControlInset + housingControlGap)
        let width = min(widthLimit, max(notch.width + controls, image.width + 2 * horizontal))
        let size = CGSize(width: width, height: image.height + clearance + bottom)
        // The controls may require a wider body than the image. Center the image
        // without stretching a narrow source to fill that extra room.
        return WorkspaceLayout(size: size, preview: CGRect(x: (width - image.width) / 2,
            y: bottom, width: image.width, height: image.height))
    }
}
