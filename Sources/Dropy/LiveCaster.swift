import AppKit
import CoreMedia
import DropyCore
import ScreenCaptureKit

/// Live mode's stream: the whole Stage, one to one, with only the windows on it that
/// belong to apps (the docked app's window and its menus, popovers and sheets, and
/// system panels it opens such as input-method candidates). The Stage's desktop, its
/// menu bar and Dropy's own windows are left out, on a clear background, so the mirror
/// over the person's display shows the app exactly where it is. The stream lives
/// exactly as long as one Live session: a forgotten stream keeps the window server busy.
@MainActor
final class LiveCaster {
    enum Failure: Error { case stageNotCapturable }

    private var stream: SCStream?
    private var mailbox: FrameMailbox?
    private var recorder: CaptureMetricsRecorder?
    private var observer: StreamStopObserver?
    private var requestID = UUID()
    func benchmarkSnapshot() -> [String: Any]? { recorder?.benchmarkSnapshot() }

    /// Streams the Stage `stage` (`size` in points) into `renderer`, showing the app
    /// with `appProcess` and floating surfaces (`PointerHandoff.shows`).
    func start(stage: CGDirectDisplayID, size: CGSize, windowID: UInt32, appProcess: Int32, renderer: MetalFrameView,
               refreshRate: Int, onUnexpectedStop: @escaping @MainActor (Error) -> Void) async throws {
        let stopping = stop(reason: "replaced")
        let request = requestID
        await stopping.value
        guard request == requestID else { throw CancellationError() }
        let requestedAt = HostClock.nowMilliseconds()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard request == requestID else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == stage }) else {
            throw Failure.stageNotCapturable
        }
        // Left out once at the start: windows created later (menus, popovers) are the
        // app's and stay in. The desktop, menu bar, Dropy's curtain and other apps'
        // windows waiting on the Stage to go home are all there before the stream starts.
        let stageBounds = CGDisplayBounds(stage)
        let excluded = content.windows.filter { window in
            let processID = window.owningApplication?.processID ?? 0
            if processID == getpid() { return true }
            guard window.frame.intersects(stageBounds) else { return false }
            return !PointerHandoff.shows(.init(bounds: window.frame, layer: window.windowLayer, processID: processID),
                                         appProcess: appProcess)
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = SCStreamConfiguration()
        let scale = renderer.window?.backingScaleFactor ?? 2
        configuration.width = max(64, Int(size.width * scale))
        configuration.height = max(64, Int(size.height * scale))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.backgroundColor = .clear
        // Full rate while the person uses the app: the idle downshift of the preview
        // would sit on the input path (BENCHMARK, idle trace).
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(30, refreshRate)))
        configuration.queueDepth = 3
        configuration.capturesAudio = false
        // Dropy draws its own cursor at once; a captured one would lag a frame or two.
        configuration.showsCursor = false
        let recorder = CaptureMetricsRecorder(windowID: windowID, requestedAt: requestedAt)
        let mailbox = FrameMailbox(renderer: renderer, metrics: recorder) { _, _ in }
        mailbox.setGeometry(CaptureGeometry(windowID: windowID, windowSize: size,
                                            pixelSize: CGSize(width: configuration.width, height: configuration.height)))
        let observer = StreamStopObserver { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == request, self.stream != nil else { return }
                // Invalidate frames before disabling input and restoring the source.
                let stopping = self.stop(reason: "unexpected(\((error as NSError).code))")
                onUnexpectedStop(error)
                await stopping.value
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: observer)
        try stream.addStreamOutput(mailbox, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "org.dropy.live.frames"))
        self.stream = stream
        self.mailbox = mailbox
        self.recorder = recorder
        self.observer = observer
        do {
            try await stream.startCapture()
            guard request == requestID, self.stream === stream else {
                // A stop while startCapture was awaiting must also stop a capture
                // which finishes starting after that earlier stop returned.
                try? await stream.stopCapture()
                throw CancellationError()
            }
            recorder.startReturned()
            NSLog("Dropy live: streaming the Stage %.0fx%.0f, %ld windows left out", size.width, size.height, excluded.count)
        } catch {
            mailbox.invalidate()
            recorder.finish(reason: "startFailed(\((error as NSError).code))")
            if self.stream === stream {
                self.stream = nil
                self.mailbox = nil
                self.recorder = nil
                self.observer = nil
            }
            throw error
        }
    }

    /// Detach synchronously: a delayed stop task must never stop a newer stream.
    @discardableResult
    func stop(reason: String = "closed") -> Task<Void, Never> {
        requestID = UUID()
        guard let stream else { return Task {} }
        mailbox?.invalidate()
        self.stream = nil
        mailbox = nil
        let recorder = self.recorder
        self.recorder = nil
        let observer = self.observer
        self.observer = nil
        return Task {
            do {
                try await stream.stopCapture()
                recorder?.finish(reason: reason)
            } catch {
                recorder?.finish(reason: "stopFailed(\((error as NSError).code))")
            }
            // Keep the delegate alive until ScreenCaptureKit has acknowledged stop.
            withExtendedLifetime(observer) {}
        }
    }
}

/// Dropy's own cursor, drawn where the person sees the cast while the real pointer is
/// on the Stage. It shows the app's current cursor (I-beam, pointing hand, resize…).
@MainActor
final class SoftCursor {
    private let panel: NSPanel
    private let imageView = NSImageView()
    private var lastImageCheck = Date.distantPast
    private var imageBytes = 0
    private var hotSpot = CGPoint(x: 5, y: 5)

    init() {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 32, height: 32),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        // Above the overlay, which is at the status-bar level.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        imageView.imageScaling = .scaleNone
        panel.contentView = imageView
        setImage(NSCursor.arrow)
    }

    /// Shows the cursor with its hot spot at `point` (global top-left).
    func show(at point: CGPoint) {
        move(to: point)
        panel.orderFrontRegardless()
    }

    func move(to point: CGPoint) {
        refreshImage()
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: point.x - hotSpot.x, y: mainHeight - point.y - (size.height - hotSpot.y)))
    }

    func hide() { panel.orderOut(nil) }

    /// The app's cursor, read at most every 50 ms. `currentSystemCursor` is deprecated
    /// since macOS 15 but still answers on 27 (spike S4); it is looked up at runtime so
    /// its removal falls back to the arrow instead of failing.
    private func refreshImage() {
        guard Date().timeIntervalSince(lastImageCheck) > 0.05 else { return }
        lastImageCheck = Date()
        let selector = NSSelectorFromString("currentSystemCursor")
        guard (NSCursor.self as AnyObject).responds(to: selector),
              let cursor = (NSCursor.self as AnyObject).perform(selector)?.takeUnretainedValue() as? NSCursor else { return }
        let bytes = cursor.image.tiffRepresentation?.count ?? 0
        guard bytes != imageBytes else { return }
        imageBytes = bytes
        setImage(cursor)
    }

    private func setImage(_ cursor: NSCursor) {
        imageView.image = cursor.image
        hotSpot = cursor.hotSpot
        panel.setContentSize(cursor.image.size)
        imageView.frame = CGRect(origin: .zero, size: cursor.image.size)
    }
}
