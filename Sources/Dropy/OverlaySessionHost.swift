import AppKit
import DropyCore

/// What a session (the live preview, the docked window) may use from the overlay that
/// hosts it. The overlay owns the panel, its outline, layout, the window list and
/// dismissal; a session owns how the chosen window is shown and used.
@MainActor
protocol OverlaySessionHost: AnyObject {
    var state: CapturePhase { get }
    func setState(_ next: CapturePhase)
    /// Changes on open, close, every selection and every failure. Async work continues
    /// only while the generation it captured is still current.
    var generation: UUID { get set }
    var selectedIdentity: WindowIdentity? { get set }
    var selectedApplicationName: String { get }
    /// Size in points of the window being shown.
    var selectedWindowSize: CGSize? { get set }
    var preferences: PreferenceStore { get }

    var panel: OverlayPanel? { get }
    var backdrop: MorphBackdropView? { get }
    var workspace: OverlayWorkspaceView? { get }
    var renderer: MetalFrameView? { get }
    var overlayScreen: NSScreen? { get }
    var notchSize: CGSize? { get }
    /// When the outline's current animation finishes.
    var settlesAt: Date { get }

    /// Sizes the overlay to the previewed window.
    func layoutSelectedWindow()
    /// Moves the overlay's body (screen coordinates) with the window area inside it.
    func applyLayout(body: CGRect, preview: CGRect, animated: Bool)
    func morphClosed(_ panel: OverlayPanel, backdrop: MorphBackdropView?, content: NSView?)
    func removeSessionWatchers()
    func reloadListKeepingState()
    func showNote(_ message: String)
    /// Shows the live preview of `identity` instead, with a note saying why.
    func showPreviewInstead(of identity: WindowIdentity, request: UUID, note: String)
    /// A restored or failed source must not keep the keyboard on the hidden Stage.
    func relinquishSourceFocus(processID: pid_t)
    func close(returnsFocus: Bool, putsBack: Bool)
}
