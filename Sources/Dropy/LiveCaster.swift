import AppKit
import CoreMedia
import DropyCore
import ScreenCaptureKit

/// Live mode's stream: the region of the Stage where the window is, captured as a
/// display region rather than a single window, so the app's menus, popovers and
/// sheets that open over the window are in the picture too. Dropy's own windows are
/// excluded. The stream lives exactly as long as one Live session: a forgotten
/// stream keeps the window server busy.
@MainActor
final class LiveCaster {
    enum Failure: Error { case stageNotCapturable }

    private var stream: SCStream?
    private var mailbox: FrameMailbox?
    private var recorder: CaptureMetricsRecorder?

    /// Streams `region` (points, relative to the Stage's top-left) into `renderer`.
    func start(stage: CGDirectDisplayID, region: CGRect, windowID: UInt32, renderer: MetalFrameView,
               refreshRate: Int) async throws {
        await stop(reason: "replaced")
        let requestedAt = HostClock.nowMilliseconds()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == stage }) else {
            throw Failure.stageNotCapturable
        }
        let dropy = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: dropy, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = renderer.window?.backingScaleFactor ?? 2
        configuration.sourceRect = region
        configuration.width = max(64, Int(region.width * scale))
        configuration.height = max(64, Int(region.height * scale))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // Full rate while the person uses the app: the idle downshift of the preview
        // would sit on the input path (BENCHMARK, idle trace).
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(30, refreshRate)))
        configuration.queueDepth = 4
        configuration.capturesAudio = false
        // Dropy draws its own cursor at once; a captured one would lag a frame or two.
        configuration.showsCursor = false
        let recorder = CaptureMetricsRecorder(windowID: windowID, requestedAt: requestedAt)
        let mailbox = FrameMailbox(renderer: renderer, metrics: recorder) { _, _ in }
        mailbox.setGeometry(CaptureGeometry(windowID: windowID, windowSize: region.size,
                                            pixelSize: CGSize(width: configuration.width, height: configuration.height)))
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(mailbox, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "org.dropy.live.frames"))
        self.stream = stream
        self.mailbox = mailbox
        self.recorder = recorder
        do {
            try await stream.startCapture()
            recorder.startReturned()
            NSLog("Dropy live: streaming %.0fx%.0f from the Stage", region.width, region.height)
        } catch {
            mailbox.invalidate()
            recorder.finish(reason: "startFailed(\((error as NSError).code))")
            self.stream = nil
            self.mailbox = nil
            self.recorder = nil
            throw error
        }
    }

    func stop(reason: String = "closed") async {
        guard let stream else { return }
        mailbox?.invalidate()
        self.stream = nil
        mailbox = nil
        let recorder = self.recorder
        self.recorder = nil
        do {
            try await stream.stopCapture()
            recorder?.finish(reason: reason)
        } catch {
            recorder?.finish(reason: "stopFailed(\((error as NSError).code))")
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
