import AppKit
import DropyCore

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class OverlayController: NSObject {
    enum State { case closed, opening, selecting, capturing, sourceUnavailable, error }

    private let preferences: PreferenceStore
    private let capture = CaptureController()
    private var panel: OverlayPanel?
    private var list: NSStackView?
    private var status: NSTextField?
    private var renderer: MetalFrameView?
    private var available: [CapturableWindow] = []
    private var selectedIdentity: WindowIdentity?
    private var identityTask: Task<Void, Never>?
    private var generation = UUID()
    private(set) var state: State = .closed

    init(preferences: PreferenceStore) {
        self.preferences = preferences
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    func toggle() {
        state == .closed ? open() : close()
    }

    func open() {
        guard state == .closed else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }
        state = .opening
        generation = UUID()
        let full = OverlayGeometry.frame(on: screen.frame,
                                         preferredSize: preferences.value.sizePreset.dimensions)
        let compact = CGRect(x: screen.frame.midX - 104, y: screen.frame.maxY - 38,
                             width: 208, height: 38)
        let panel = OverlayPanel(contentRect: compact, styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        panel.isOpaque = true
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        buildContent(in: panel, size: full.size)
        self.panel = panel
        panel.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(full, display: true)
        }
        state = .selecting
        refreshWindows()
    }

    func close() {
        guard state != .closed else { return }
        generation = UUID()
        state = .closed
        selectedIdentity = nil
        identityTask?.cancel()
        identityTask = nil
        panel?.orderOut(nil)
        panel = nil
        list = nil
        status = nil
        renderer?.clear()
        renderer = nil
        Task { await capture.stop() }
    }

    func refreshWindows() {
        guard state != .closed else { return }
        let request = generation
        status?.stringValue = "Finding open windows…"
        Task {
            do {
                let windows = try await WindowCatalog.availableWindows()
                guard request == generation, state != .closed else { return }
                available = windows
                rebuildWindowList()
                let shouldAutoSelect = state == .selecting
                if state == .sourceUnavailable { state = .selecting }
                if state == .selecting || state == .opening {
                    status?.stringValue = windows.isEmpty
                        ? "No capturable windows. Open an app and refresh."
                        : "Choose a window · live preview only"
                }
                let preferredBundleID: String?
                switch preferences.value.openBehavior {
                case .direct: preferredBundleID = preferences.value.selectedBundleIdentifier
                case .lastUsed: preferredBundleID = preferences.value.lastUsedBundleIdentifier
                case .picker: preferredBundleID = nil
                }
                if shouldAutoSelect, let bundleID = preferredBundleID,
                   let index = windows.firstIndex(where: { $0.bundleIdentifier == bundleID }) {
                    selectWindow(at: index)
                }
            } catch {
                guard request == generation else { return }
                state = .error
                status?.stringValue = "Capture unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func buildContent(in panel: NSPanel, size: CGSize) {
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
        root.layer?.cornerRadius = 26
        root.layer?.masksToBounds = true
        panel.contentView = root

        let title = NSTextField(labelWithString: "DROPY")
        title.frame = CGRect(x: 26, y: size.height - 64, width: 220, height: 28)
        title.font = .boldSystemFont(ofSize: 21)
        title.textColor = .white
        root.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Your apps, near the notch")
        subtitle.frame = CGRect(x: 27, y: size.height - 85, width: 270, height: 18)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        root.addSubview(subtitle)

        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.frame = CGRect(x: size.width - 90, y: size.height - 65, width: 66, height: 28)
        root.addSubview(close)

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refresh.frame = CGRect(x: 22, y: size.height - 124, width: 90, height: 27)
        root.addSubview(refresh)

        let scroll = NSScrollView(frame: CGRect(x: 18, y: 50,
                                                width: 252, height: size.height - 185))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView(frame: CGRect(x: 0, y: 0, width: 230, height: 1))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        scroll.documentView = stack
        root.addSubview(scroll)
        list = stack

        let previewFrame = CGRect(x: 288, y: 50,
                                  width: max(100, size.width - 312),
                                  height: max(100, size.height - 145))
        let previewShell = NSView(frame: previewFrame)
        previewShell.wantsLayer = true
        previewShell.layer?.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 1).cgColor
        previewShell.layer?.cornerRadius = 16
        previewShell.layer?.masksToBounds = true
        root.addSubview(previewShell)
        do {
            let view = try MetalFrameView.make(frame: previewShell.bounds)
            view.autoresizingMask = [.width, .height]
            view.contentMode = preferences.value.contentMode
            previewShell.addSubview(view)
            renderer = view
        } catch {
            let failure = NSTextField(labelWithString: "Metal unavailable: \(error.localizedDescription)")
            failure.frame = CGRect(x: 15, y: 15, width: previewFrame.width - 30, height: 80)
            failure.textColor = .systemRed
            previewShell.addSubview(failure)
        }

        let status = NSTextField(labelWithString: "Finding open windows…")
        status.frame = CGRect(x: 288, y: 20, width: max(100, size.width - 310), height: 20)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        root.addSubview(status)
        self.status = status
    }

    private func rebuildWindowList() {
        guard let list else { return }
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, window) in available.enumerated() {
            let button = NSButton(title: window.displayName, target: self,
                                  action: #selector(windowClicked(_:)))
            button.frame = CGRect(x: 0, y: 0, width: 226, height: 42)
            button.tag = index
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            list.addArrangedSubview(button)
        }
        list.frame.size.height = max(CGFloat(available.count) * 49, 1)
    }

    private func selectWindow(at index: Int) {
        guard available.indices.contains(index), let renderer else { return }
        let selected = available[index]
        let request = UUID()
        generation = request
        identityTask?.cancel()
        identityTask = nil
        selectedIdentity = selected.identity
        if let bundleID = selected.bundleIdentifier {
            preferences.update {
                $0.lastUsedBundleIdentifier = bundleID
                if $0.openBehavior == .direct { $0.selectedBundleIdentifier = bundleID }
            }
        }
        status?.stringValue = "Starting preview: \(selected.applicationName)…"
        state = .capturing
        Task {
            do {
                guard let current = try await WindowCatalog.resolve(selected.identity) else {
                    await selectedWindowClosed(request: request)
                    return
                }
                guard request == generation, state == .capturing,
                      selectedIdentity == selected.identity else { return }
                try await capture.start(window: current, renderer: renderer)
                guard request == generation, state == .capturing,
                      selectedIdentity == selected.identity else { return }
                status?.stringValue = "Live preview · interaction bridge not enabled yet"
                monitorWindow(selected.identity, request: request, renderer: renderer)
            } catch {
                guard request == generation else { return }
                state = .error
                status?.stringValue = "Preview failed: \(error.localizedDescription)"
            }
        }
    }

    private func monitorWindow(_ identity: WindowIdentity, request: UUID,
                               renderer: MetalFrameView) {
        identityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self,
                      request == self.generation, self.state == .capturing,
                      self.selectedIdentity == identity else { return }
                do {
                    guard let current = try await WindowCatalog.resolve(identity) else {
                        await self.selectedWindowClosed(request: request)
                        return
                    }
                    guard !Task.isCancelled, request == self.generation else { return }
                    try await self.capture.updateWindow(current, renderer: renderer)
                } catch {
                    guard !Task.isCancelled, request == self.generation else { return }
                    self.state = .error
                    self.status?.stringValue = "Window check failed: \(error.localizedDescription)"
                    await self.capture.stop()
                    if request == self.generation { self.renderer?.clear() }
                    return
                }
            }
        }
    }

    private func selectedWindowClosed(request: UUID) async {
        guard request == generation, state == .capturing else { return }
        generation = UUID()
        let invalidatedRequest = generation
        selectedIdentity = nil
        identityTask?.cancel()
        identityTask = nil
        available = []
        rebuildWindowList()
        renderer?.clear()
        state = .sourceUnavailable
        status?.stringValue = "Source window closed. Refresh to choose another."
        await capture.stop()
        if generation == invalidatedRequest, state == .sourceUnavailable { renderer?.clear() }
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let identity = selectedIdentity,
              application.processIdentifier == identity.processID,
              application.launchDate == identity.processLaunchDate,
              application.bundleIdentifier == identity.bundleIdentifier else { return }
        let request = generation
        Task { await selectedWindowClosed(request: request) }
    }

    @objc private func closeClicked() { close() }
    @objc private func refreshClicked() { refreshWindows() }
    @objc private func windowClicked(_ button: NSButton) { selectWindow(at: button.tag) }
}
