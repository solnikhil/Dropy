import AppKit
import DropyCore

@main
struct WorkspaceChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let notch = CGSize(width: 208, height: 37.5)
        let layout = WorkspaceLayout.make(source: CGSize(width: 310, height: 200),
                                         screen: CGSize(width: 1710, height: 1112), notch: notch, expanded: false)
        let view = OverlayWorkspaceView(frame: CGRect(origin: .zero, size: layout.size))
        view.previewRect = layout.preview
        view.showsPreview = true
        view.layoutSubtreeIfNeeded()
        precondition(view.previewShell.frame == layout.preview, "presentation must use the calculated input viewport")
        precondition(view.scroll.isHidden && !view.previewShell.isHidden, "a selected window must own the workspace")
        let housing = CGRect(x: (layout.size.width - notch.width) / 2,
                             y: layout.size.height - notch.height, width: notch.width, height: notch.height)
        precondition(!view.apps.frame.intersects(housing) && !view.expand.frame.intersects(housing),
                     "controls must stay outside the physical housing")
        precondition(view.interaction.isHidden, "capability messages must remain hidden until an attempted action")
        precondition(view.previewShell.frame.minY == 8, "the preview must not reserve an unused status footer")
        let menu = NSMenu()
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let icon = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)!
        icon.size = CGSize(width: 16, height: 16)
        item.image = icon
        menu.addItem(item)
        view.apps.menu = menu
        precondition(view.apps.frame.width >= view.apps.intrinsicContentSize.width, "app icon and arrow must fit without clipping")
        let narrow = WorkspaceLayout.make(source: CGSize(width: 160, height: 300),
            screen: CGSize(width: 1710, height: 1112), notch: notch, expanded: false)
        let narrowView = OverlayWorkspaceView(frame: CGRect(origin: .zero, size: narrow.size))
        narrowView.previewRect = narrow.preview
        narrowView.showsPreview = true
        narrowView.layoutSubtreeIfNeeded()
        let narrowHousing = CGRect(x: (narrow.size.width - notch.width) / 2,
            y: narrow.size.height - notch.height, width: notch.width, height: notch.height)
        precondition(!narrowView.apps.frame.intersects(narrowHousing), "the wider switcher must remain outside the housing for narrow source windows")
        let rendererStandIn = NSView(frame: view.previewShell.bounds)
        rendererStandIn.autoresizingMask = [.width, .height]
        view.previewShell.addSubview(rendererStandIn)
        let expanded = WorkspaceLayout.make(source: CGSize(width: 310, height: 200),
            screen: CGSize(width: 1710, height: 1112), notch: notch, expanded: true)
        view.frame.size = expanded.size
        view.previewRect = expanded.preview
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        precondition(rendererStandIn.frame.size == expanded.preview.size, "the retained renderer must follow the new viewport")
        view.showsPreview = false
        view.layoutSubtreeIfNeeded()
        precondition(!view.scroll.isHidden && view.previewShell.isHidden, "the chooser must replace, not crowd, the preview")
        print("Workspace layout checks passed (no windows shown)")
    }
}
