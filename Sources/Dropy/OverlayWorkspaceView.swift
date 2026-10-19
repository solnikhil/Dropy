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
    let searchSurface = PickerSearchSurface()
    var searchShowsFocus = false { didSet { updateSearchFocus() } }
    private func updateSearchFocus() {
        searchSurface.layer?.borderColor = NSColor.white.withAlphaComponent(searchShowsFocus ? 0.30 : 0.10).cgColor
    }
    let pickerCount = NSTextField(labelWithString: "")
    let pickerSection = NSTextField(labelWithString: "OPEN WINDOWS")
    private let pickerDivider = NSView()
    private let footerDivider = NSView()
    let scroll = NSScrollView()
    let windowList = NSStackView()
    let previewShell = NSView()
    let status = NSTextField(wrappingLabelWithString: "Finding open windows…")
    let pickerHeading = NSTextField(labelWithString: "Switch window")
    let pickerHint = NSTextField(labelWithString: "↑ ↓  Navigate     ↵  Open     esc  Close")
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
        searchSurface.searchField = search
        search.placeholderString = "Search apps or windows…"
        search.font = .systemFont(ofSize: 13)
        search.focusRingType = .none
        search.isBezeled = false
        search.isBordered = false
        search.drawsBackground = false
        searchSurface.wantsLayer = true
        searchSurface.layer?.backgroundColor = NSColor(white: 1, alpha: 0.055).cgColor
        searchSurface.layer?.cornerRadius = 10
        searchSurface.layer?.borderWidth = 1
        updateSearchFocus()
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search apps and windows")
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        windowList.orientation = .vertical
        windowList.alignment = .leading
        windowList.spacing = WindowPickerLayout.rowSpacing
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
        pickerHeading.font = .systemFont(ofSize: 20, weight: .semibold)
        pickerCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        pickerCount.textColor = NSColor(white: 0.52, alpha: 1)
        pickerCount.alignment = .right
        pickerSection.font = .systemFont(ofSize: 9, weight: .semibold)
        pickerSection.textColor = NSColor(white: 0.46, alpha: 1)
        for divider in [pickerDivider, footerDivider] {
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        }
        pickerHeading.textColor = NSColor(white: 0.95, alpha: 1)
        pickerHint.font = .systemFont(ofSize: 10)
        pickerHint.textColor = NSColor(white: 0.48, alpha: 1)
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
        for view in [apps, expand, pin, searchSurface, search, scroll, previewShell, status, pickerHeading, pickerCount, pickerSection, pickerDivider, footerDivider, pickerHint, emptyIcon, interaction, privacy, elsewhere] { addSubview(view) }
    }
    /// Layout must settle before scrolling after a catalog rebuild or search.
    func revealSelectedWindow() {
        layoutSubtreeIfNeeded()
        if let row = windowList.arrangedSubviews.compactMap({ $0 as? WindowChoiceButton }).first(where: \.keyboardSelected) {
            row.scrollToVisible(row.bounds)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() {
        super.layout()
        apps.frame = CGRect(x: WorkspaceLayout.topControlInset, y: bounds.height - 30,
                            width: WorkspaceLayout.appSwitcherWidth, height: 24)
        expand.frame = CGRect(x: bounds.width - 38, y: bounds.height - 30, width: 28, height: 24)
        expand.isHidden = !showsPreview || docked
        pin.frame = CGRect(x: bounds.width - (expand.isHidden ? 38 : 70), y: bounds.height - 30, width: 28, height: 24)
        previewShell.frame = previewRect
        // Explicit viewport ownership avoids AppKit autoresizing accumulating an
        // old size during a detached or hidden shell’s layout transition.
        for child in previewShell.subviews { child.frame = previewShell.bounds }
        previewShell.isHidden = docked ? !coversWindow : !showsPreview
        cover.isHidden = !docked
        let choosing = !showsPreview && !docked
        pickerHeading.frame = CGRect(x: 20, y: bounds.height - 72, width: max(1, bounds.width - 130), height: 26)
        pickerCount.frame = CGRect(x: bounds.width - 108, y: bounds.height - 65, width: 88, height: 16)
        pickerSection.frame = CGRect(x: 22, y: bounds.height - 153, width: max(1, bounds.width - 44), height: 12)
        pickerDivider.frame = CGRect(x: 20, y: bounds.height - 132, width: max(1, bounds.width - 40), height: 1)
        footerDivider.frame = CGRect(x: 20, y: 76, width: max(1, bounds.width - 40), height: 1)
        for view in [pickerHeading, pickerCount, pickerSection, pickerDivider, footerDivider] { view.isHidden = !choosing }
        pickerHint.frame = CGRect(x: 22, y: 16, width: max(1, bounds.width - 44), height: 16)
        pickerHint.isHidden = !choosing || !privacy.isHidden
        searchSurface.frame = CGRect(x: 20, y: bounds.height - 120, width: max(1, bounds.width - 40), height: 36)
        // A native-height field keeps placeholder, caret and selection aligned.
        search.frame = searchSurface.frame.insetBy(dx: 6, dy: 7)
        searchSurface.isHidden = !choosing
        search.isHidden = !choosing
        scroll.frame = CGRect(x: 16, y: 82, width: max(1, bounds.width - 32), height: max(1, bounds.height - 246))
        scroll.isHidden = !choosing
        interaction.frame = CGRect(x: 12, y: previewRect.minY + 8,
                                   width: max(1, bounds.width - 24), height: 36)
        elsewhere.frame = CGRect(x: previewRect.midX - 90, y: previewRect.midY - 62, width: 180, height: 28)
        let emptyPicker = choosing && windowList.arrangedSubviews.isEmpty
        emptyIcon.frame = CGRect(x: bounds.midX - 18, y: scroll.frame.midY + 10, width: 36, height: 36)
        emptyIcon.isHidden = !emptyPicker
        status.alignment = showsPreview || docked || emptyPicker ? .center : .left
        status.font = .systemFont(ofSize: choosing ? 11 : 12)
        if emptyPicker {
            status.frame = CGRect(x: 32, y: scroll.frame.midY - 48, width: max(1, bounds.width - 64), height: 48)
        } else if choosing {
            status.frame = CGRect(x: 22, y: 39, width: max(1, bounds.width - 44), height: 28)
        } else {
            status.frame = CGRect(x: 20, y: previewRect.midY - 26, width: max(1, bounds.width - 40), height: 52)
        }
        privacy.frame = CGRect(x: 20, y: 10, width: 180, height: 28)
        let rowWidth = max(1, scroll.contentSize.width)
        for row in windowList.arrangedSubviews { row.frame.size.width = rowWidth }
        let count = windowList.arrangedSubviews.count
        windowList.frame.size = CGSize(width: rowWidth, height: max(1,
            CGFloat(count) * WindowPickerLayout.rowHeight + CGFloat(max(0, count - 1)) * WindowPickerLayout.rowSpacing))
    }
}

/// Padding around the native search field remains part of its click target.
@MainActor
final class PickerSearchSurface: NSView {
    weak var searchField: NSSearchField?
    override func mouseDown(with event: NSEvent) {
        guard let searchField else { return }
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
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
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        let active = keyboardSelected || (cell?.isHighlighted ?? false)
        (active ? NSColor.white.withAlphaComponent(0.10)
         : NSColor.white.withAlphaComponent(hovered ? 0.055 : 0.015)).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(active ? 0.17 : (hovered ? 0.07 : 0.025)).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let iconRect = CGRect(x: 12, y: (bounds.height - 28) / 2, width: 28, height: 28)
        appIcon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(white: 0.94, alpha: 1), .paragraphStyle: paragraph]
        let detail: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(white: 0.62, alpha: 1), .paragraphStyle: paragraph]
        let width = max(1, bounds.width - 90)
        let nameY: CGFloat = isFlipped ? 6 : bounds.height - 23
        let detailY: CGFloat = isFlipped ? 25 : 7
        (appName as NSString).draw(in: CGRect(x: 54, y: nameY, width: width, height: 17), withAttributes: attributes)
        (documentName as NSString).draw(in: CGRect(x: 54, y: detailY, width: width, height: 15), withAttributes: detail)
        if active || hovered {
            let key = CGRect(x: bounds.width - 34, y: (bounds.height - 22) / 2, width: 24, height: 22)
            NSColor.white.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: key, xRadius: 5, yRadius: 5).fill()
            ("↵" as NSString).draw(in: key.offsetBy(dx: 6, dy: 2), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(white: 0.83, alpha: 1)])
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}
