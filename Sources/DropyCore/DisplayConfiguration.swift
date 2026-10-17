import CoreGraphics

/// A display's coordinate and rendering contract. IDs alone do not detect a Retina
/// scale change, a menu-bar/Dock change or a different refresh rate.
public struct DisplayConfiguration: Equatable, Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let scale: CGFloat
    public let refreshRate: Int

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect, scale: CGFloat, refreshRate: Int) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.refreshRate = refreshRate
    }
}
