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
        precondition(!view.apps.frame.intersects(housing) && !view.expand.frame.intersects(housing) && !view.pin.frame.intersects(housing),
                     "controls must stay outside the physical housing")
        precondition(!view.pin.frame.intersects(view.expand.frame), "pin and expand must have distinct targets")
        precondition(!view.pin.isHidden && view.pin.state == .off)
        view.isPinned = true
        precondition(view.pin.state == .on && view.pin.accessibilityLabel() == "Unpin overlay")
        view.isPinned = false
        precondition(view.pin.state == .off)
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
        precondition(!narrowView.pin.frame.intersects(narrowHousing) && !narrowView.expand.frame.intersects(narrowHousing))
        precondition(narrow.preview.size == CGSize(width: 160, height: 300), "control room must not stretch the monitored source")
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
        precondition(!view.search.isHidden, "the chooser exposes search")
        precondition(view.search.frame.minY >= view.scroll.frame.maxY, "search must not overlap the rows")
        precondition(view.search.frame.maxY <= view.pickerHeading.frame.minY, "search must stay below the heading")
        precondition(view.search.focusRingType == .none, "search uses its own focus treatment")
        view.searchShowsFocus = true
        precondition(view.searchSurface.layer?.borderColor != nil)
        let picker = OverlayWorkspaceView(frame: CGRect(origin: .zero, size: WindowPickerLayout.preferredSize))
        for i in 0..<8 {
            let row = WindowChoiceButton(title: "", target: nil, action: nil)
            row.configure(appName: "Application", windowTitle: "Document \(i)", icon: nil)
            row.heightAnchor.constraint(equalToConstant: WindowPickerLayout.rowHeight).isActive = true
            picker.windowList.addArrangedSubview(row)
        }
        picker.needsLayout = true
        picker.layoutSubtreeIfNeeded()
        precondition(picker.searchSurface.frame.height == 36 && picker.search.frame.height == 22)
        precondition(picker.search.frame.midY == picker.searchSurface.frame.midY,
                     "the native search field must be centered in its surface")
        precondition(picker.scroll.frame.minY > picker.status.frame.maxY)
        precondition(picker.search.frame.minY > picker.scroll.frame.maxY)
        precondition(picker.windowList.frame.height > picker.scroll.frame.height, "long catalogs must scroll")
        precondition(!picker.pickerHeading.isHidden && !picker.pickerCount.isHidden)
        picker.showsPreview = true
        picker.layoutSubtreeIfNeeded()
        precondition(picker.pickerHeading.isHidden && picker.pickerCount.isHidden && picker.pickerSection.isHidden)
        view.docked = true
        view.layoutSubtreeIfNeeded()
        precondition(view.search.isHidden && view.scroll.isHidden, "search must never intercept a docked app")
        precondition(!view.pin.isHidden, "monitoring must be reachable from a real docked window")
        print("Workspace layout checks passed (no windows shown)")
    }
}
