import AppKit
import SwiftUI
import DropyCore

/// The Animation Studio window. One file is open at a time; opening another replaces it.
@MainActor
final class AnimationStudioController: NSObject, NSWindowDelegate {
    private let library: AnimationLibrary
    private var window: NSWindow?
    private(set) var model: AnimationStudioModel?
    var playOnNotch: ((DropyAnimation, Double) -> TimeInterval)?
    var use: ((String) -> Void)?
    var inUse: (String) -> Bool = { _ in false }
    /// Called when the window appears or closes (for the Dock icon).
    var onVisibilityChange: (() -> Void)?

    init(library: AnimationLibrary) {
        self.library = library
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Opens `fileID` (a file in the animations folder).
    func open(_ fileID: String) {
        library.scan()
        guard let entry = library.entry(fileID) else { return }
        guard let animation = entry.animation else {
            // A file with errors opens in the editor the person wrote it with.
            NSWorkspace.shared.open(entry.url)
            return
        }
        model?.saveNow()
        let model = AnimationStudioModel(library: library, fileID: fileID, animation: animation)
        model.playOnNotch = playOnNotch
        model.use = use
        model.inUse = { [weak self] in self?.inUse(fileID) ?? false }
        model.openFile = { [weak self] id in self?.open(id) }
        self.model = model
        let window = self.window ?? makeWindow()
        let host = NSHostingController(rootView: AnimationStudioView(model: model))
        // The window keeps the size the person gave it; SwiftUI content does not resize it.
        host.sizingOptions = []
        let frame = window.frame
        window.contentViewController = host
        if self.window != nil { window.setFrame(frame, display: false) }
        window.title = "\(animation.name) — Animation Studio"
        if self.window == nil {
            window.setContentSize(CGSize(width: 1120, height: 760))
            window.center()
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onVisibilityChange?()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 980, height: 660)
        window.setFrameAutosaveName("DropyAnimationStudio")
        window.delegate = self
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.155, green: 0.155, blue: 0.162, alpha: 1)
                : NSColor(srgbRed: 0.940, green: 0.940, blue: 0.945, alpha: 1)
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model?.saveNow()
        DispatchQueue.main.async { [weak self] in self?.onVisibilityChange?() }
    }
}
