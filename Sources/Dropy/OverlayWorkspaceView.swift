import AppKit
import DropyCore

/// Presentation only. Capture, docking and selected-window identity remain owned by
/// their coordinators; every size uses the same renderer instance.
@MainActor
final class OverlayWorkspaceView: NSView {
    let apps = NSPopUpButton(frame: .zero, pullsDown: true)
    let expand = NSButton()
    let pin = NSButton()
    var isPinned = false { didSet { updatePin() } }

    private func updatePin() {
        pin.state = isPinned ? .on : .off
        pin.contentTintColor = isPinned ? DropyAppearance.accent : NSColor(white: 0.8, alpha: 1)
        pin.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        let label = isPinned ? "Unpin overlay" : "Pin overlay for monitoring"
        pin.toolTip = isPinned ? "Unpin overlay · Restore normal dismissal and interaction" : "Pin overlay · Keep a view-only monitor visible across desktops"
        pin.setAccessibilityLabel(label)
    }
    let search = NSSearchField()
    let scroll = NSScrollView()
    let windowList = NSStackView()
    let previewShell = NSView()
    let status = NSTextField(wrappingLabelWithString: "Finding open windows…")
    let pickerHeading = NSTextField(labelWithString: "Choose a window")
    let pickerHint = NSTextField(labelWithString: "Type to search   ·   ↑ ↓ to choose   ·   Return to open   ·   Esc to close")
    private let emptyIcon = NSImageView()
    let interaction = NSTextField(wrappingLabelWithString: "")
    let privacy = NSButton(title: "Open Privacy Settings", target: nil, action: nil)
    /// Shows a docked window that cannot come here (another desktop, full screen).
    let elsewhere = NSButton(title: "Go to Its Desktop", target: nil, action: nil)
    /// Covers the real window's place, with its app's icon, while it moves in or out.
    let cover = WindowCover()
    var previewRect = CGRect.zero
    var showsPreview = false { didSet { needsLayout = true } }
    /// The real window is in the overlay: no window list and no live preview.
    var docked = false { didSet { needsLayout = true } }
    /// While docked, whether the cover hides the window's place.
    var coversWindow = true { didSet { needsLayout = true } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        apps.bezelStyle = .inline
        apps.toolTip = "Choose an app window"
        apps.setAccessibilityLabel("Choose an app window")
        expand.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Expand preview")
        expand.bezelStyle = .inline
        expand.toolTip = "Expand or return to window size"
        expand.setAccessibilityLabel("Expand or return to window size")
        pin.bezelStyle = .inline
        pin.setButtonType(.toggle)
        updatePin()
        search.placeholderString = "Search apps and windows"
        search.setAccessibilityLabel("Search apps and windows")
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        windowList.orientation = .vertical
        windowList.alignment = .leading
        windowList.spacing = 6
        scroll.documentView = windowList
        previewShell.wantsLayer = true
        previewShell.layer?.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 1).cgColor
        previewShell.layer?.cornerRadius = 12
        status.font = .systemFont(ofSize: 12)
        status.textColor = NSColor(white: 0.65, alpha: 1)
        emptyIcon.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        emptyIcon.contentTintColor = NSColor(white: 0.48, alpha: 1)
        emptyIcon.imageScaling = .scaleProportionallyUpOrDown
        emptyIcon.setAccessibilityElement(false)
        pickerHeading.font = .systemFont(ofSize: 19, weight: .semibold)
        pickerHeading.textColor = NSColor(white: 0.95, alpha: 1)
        pickerHint.font = .systemFont(ofSize: 10)
        pickerHint.textColor = NSColor(white: 0.60, alpha: 1)
        pickerHint.setAccessibilityElement(false)
        interaction.font = .systemFont(ofSize: 10)
        interaction.textColor = NSColor(white: 0.78, alpha: 1)
        interaction.maximumNumberOfLines = 2
        interaction.isHidden = true
        interaction.wantsLayer = true
        interaction.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
        interaction.layer?.cornerRadius = 6
        privacy.isHidden = true
        elsewhere.isHidden = true
        elsewhere.bezelStyle = .rounded
        previewShell.addSubview(cover)
        for view in [apps, expand, pin, search, scroll, previewShell, status, pickerHeading, pickerHint, emptyIcon, interaction, privacy, elsewhere] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() {
        super.layout()
        apps.frame = CGRect(x: WorkspaceLayout.topControlInset, y: bounds.height - 30,
                            width: WorkspaceLayout.appSwitcherWidth, height: 24)
        expand.frame = CGRect(x: bounds.width - 38, y: bounds.height - 30, width: 28, height: 24)
        pin.frame = CGRect(x: bounds.width - 70, y: bounds.height - 30, width: 28, height: 24)
        expand.isHidden = !showsPreview || docked
        previewShell.frame = previewRect
        // Explicit viewport ownership avoids AppKit autoresizing accumulating an
        // old size during a detached or hidden shell’s layout transition.
        for child in previewShell.subviews { child.frame = previewShell.bounds }
        previewShell.isHidden = docked ? !coversWindow : !showsPreview
        cover.isHidden = !docked
        pickerHeading.frame = CGRect(x: 16, y: bounds.height - 72, width: max(1, bounds.width - 32), height: 26)
        pickerHeading.isHidden = showsPreview || docked
        pickerHint.frame = CGRect(x: 16, y: 16, width: max(1, bounds.width - 32), height: 16)
        pickerHint.isHidden = showsPreview || docked || !privacy.isHidden
        search.frame = CGRect(x: 16, y: bounds.height - 106, width: max(1, bounds.width - 32), height: 26)
        search.isHidden = showsPreview || docked
        scroll.frame = CGRect(x: 12, y: 76, width: max(1, bounds.width - 24), height: max(1, bounds.height - 194))
        scroll.isHidden = showsPreview || docked
        interaction.frame = CGRect(x: 12, y: previewRect.minY + 8,
                                   width: max(1, bounds.width - 24), height: 36)
        elsewhere.frame = CGRect(x: previewRect.midX - 90, y: previewRect.midY - 62, width: 180, height: 28)
        let emptyPicker = !showsPreview && !docked && windowList.arrangedSubviews.isEmpty
        emptyIcon.frame = CGRect(x: bounds.midX - 22, y: bounds.midY + 12, width: 44, height: 44)
        emptyIcon.isHidden = !emptyPicker
        status.alignment = showsPreview || docked || emptyPicker ? .center : .left
        status.frame = showsPreview || docked || emptyPicker
            ? CGRect(x: 20, y: previewRect.midY - 26, width: max(1, bounds.width - 40), height: 52)
            : CGRect(x: 12, y: 42, width: max(1, bounds.width - 24), height: 32)
        privacy.frame = CGRect(x: 12, y: 8, width: 180, height: 28)
        let rowWidth = max(1, scroll.contentSize.width - 8)
        for row in windowList.arrangedSubviews { row.frame.size.width = rowWidth }
        windowList.frame.size = CGSize(width: rowWidth, height: max(1, CGFloat(windowList.arrangedSubviews.count) * 58))
    }
}

/// What stands in for a docked window while it moves in or out: the app's icon on the
/// overlay's dark. Dropy takes no picture of the window, because any screen capture,
/// even of one window, tells every app on the Mac that the screen is being recorded,
/// and some video players stop playing when they hear it.
@MainActor
final class WindowCover: NSView {
    private let icon = NSImageView()
    private static let iconSide: CGFloat = 64

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the icon of the app with `processID`, or no icon.
    func show(processID: pid_t?) {
        icon.image = processID.flatMap { NSRunningApplication(processIdentifier: $0)?.icon }
    }

    override func layout() {
        super.layout()
        let side = min(Self.iconSide, bounds.width / 2, bounds.height / 2)
        icon.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }
}

/// A catalog refresh must never reinterpret an old row index as another window.
@MainActor
final class WindowChoiceButton: NSButton {
    var identity: WindowIdentity?
    var keyboardSelected = false { didSet { needsDisplay = true } }
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    private var appName = ""
    private var documentName = ""
    private var appIcon: NSImage?

    func configure(appName: String, windowTitle: String, icon: NSImage?) {
        self.appName = appName
        documentName = windowTitle.isEmpty ? "Untitled window" : windowTitle
        appIcon = icon
        isBordered = false
        focusRingType = .exterior
        setButtonType(.momentaryPushIn)
        setAccessibilityLabel("\(appName), \(documentName)")
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 11, yRadius: 11)
        let active = keyboardSelected || (cell?.isHighlighted ?? false)
        (active ? DropyAppearance.accent.withAlphaComponent(0.14)
         : NSColor.white.withAlphaComponent(hovered ? 0.09 : 0.035)).setFill()
        shape.fill()
        (active ? DropyAppearance.accent.withAlphaComponent(0.5) : NSColor.white.withAlphaComponent(0.065)).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let iconRect = CGRect(x: 12, y: (bounds.height - 30) / 2, width: 30, height: 30)
        appIcon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(white: 0.94, alpha: 1), .paragraphStyle: paragraph]
        let detail: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(white: 0.62, alpha: 1), .paragraphStyle: paragraph]
        let width = max(1, bounds.width - 90)
        let nameY: CGFloat = isFlipped ? 9 : bounds.height - 25
        let detailY: CGFloat = isFlipped ? 28 : 9
        (appName as NSString).draw(in: CGRect(x: 54, y: nameY, width: width, height: 17), withAttributes: attributes)
        (documentName as NSString).draw(in: CGRect(x: 54, y: detailY, width: width, height: 15), withAttributes: detail)
        if active || hovered {
            let symbol = NSImage(systemSymbolName: "return", accessibilityDescription: nil)
            symbol?.draw(in: CGRect(x: bounds.width - 27, y: (bounds.height - 12) / 2, width: 14, height: 12),
                         from: .zero, operation: .sourceOver, fraction: 0.6, respectFlipped: true, hints: nil)
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 11, yRadius: 11).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}
