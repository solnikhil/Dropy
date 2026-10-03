import AppKit
import DropyCore

/// Presentation only. Capture, selected-window identity and input remain owned by
/// their existing coordinators; every size uses the same renderer instance.
@MainActor
final class OverlayWorkspaceView: NSView {
    let apps = NSPopUpButton(frame: .zero, pullsDown: true)
    let expand = NSButton()
    let scroll = NSScrollView()
    let windowList = NSStackView()
    let previewShell = NSView()
    let status = NSTextField(wrappingLabelWithString: "Finding open windows…")
    let interaction = NSTextField(wrappingLabelWithString: "")
    let privacy = NSButton(title: "Open Privacy Settings", target: nil, action: nil)
    var previewRect = CGRect.zero
    var showsPreview = false { didSet { needsLayout = true } }

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
        status.textColor = .secondaryLabelColor
        interaction.font = .systemFont(ofSize: 10)
        interaction.textColor = .secondaryLabelColor
        interaction.maximumNumberOfLines = 2
        interaction.isHidden = true
        interaction.wantsLayer = true
        interaction.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
        interaction.layer?.cornerRadius = 6
        privacy.isHidden = true
        for view in [apps, expand, scroll, previewShell, status, interaction, privacy] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() {
        super.layout()
        apps.frame = CGRect(x: WorkspaceLayout.topControlInset, y: bounds.height - 30,
                            width: WorkspaceLayout.appSwitcherWidth, height: 24)
        expand.frame = CGRect(x: bounds.width - 38, y: bounds.height - 30, width: 28, height: 24)
        expand.isHidden = !showsPreview
        previewShell.frame = previewRect
        // Explicit viewport ownership avoids AppKit autoresizing accumulating an
        // old size during a detached or hidden shell’s layout transition.
        for child in previewShell.subviews { child.frame = previewShell.bounds }
        previewShell.isHidden = !showsPreview
        scroll.frame = CGRect(x: 12, y: 76, width: max(1, bounds.width - 24), height: max(1, bounds.height - 126))
        scroll.isHidden = showsPreview
        interaction.frame = CGRect(x: 12, y: previewRect.minY + 8,
                                   width: max(1, bounds.width - 24), height: 36)
        status.frame = showsPreview
            ? CGRect(x: 20, y: previewRect.midY - 26, width: max(1, bounds.width - 40), height: 52)
            : CGRect(x: 12, y: 42, width: max(1, bounds.width - 24), height: 32)
        privacy.frame = CGRect(x: 12, y: 8, width: 180, height: 28)
        let rowWidth = max(1, scroll.contentSize.width - 8)
        for row in windowList.arrangedSubviews { row.frame.size.width = rowWidth }
        windowList.frame.size = CGSize(width: rowWidth, height: max(1, CGFloat(windowList.arrangedSubviews.count) * 48))
    }
}

/// A catalog refresh must never reinterpret an old row index as another window.
@MainActor
final class WindowChoiceButton: NSButton {
    var identity: WindowIdentity?
}
