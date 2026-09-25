import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import ScreenCaptureKit

/// The stream callback only replaces a bounded latest-frame slot. Rendering runs
/// on the main thread; an overloaded UI drops stale frames instead of queueing them.
final class FrameMailbox: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var scheduled = false
    private var loggedFormat = false
    private weak var renderer: MetalFrameView?
    private(set) var receivedFrames = 0
    private(set) var droppedFrames = 0

    init(renderer: MetalFrameView) { self.renderer = renderer }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        if !loggedFormat {
            loggedFormat = true
            let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue()
            NSLog("Dropy frame: pixel=%ldx%ld format=%u row=%ld surface=%ldx%ld format=%u row=%ld",
                  CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image),
                  CVPixelBufferGetPixelFormatType(image), CVPixelBufferGetBytesPerRow(image),
                  surface.map { IOSurfaceGetWidth($0) } ?? 0,
                  surface.map { IOSurfaceGetHeight($0) } ?? 0,
                  surface.map { IOSurfaceGetPixelFormat($0) } ?? 0,
                  surface.map { IOSurfaceGetBytesPerRow($0) } ?? 0)
        }
        receivedFrames += 1
        if latest != nil { droppedFrames += 1 }
        latest = image
        let shouldSchedule = !scheduled
        if shouldSchedule { scheduled = true }
        lock.unlock()
        if shouldSchedule { DispatchQueue.main.async { self.deliverLatest() } }
    }

    @MainActor private func deliverLatest() {
        lock.lock()
        let image = latest
        latest = nil
        scheduled = false
        lock.unlock()
        if let image { renderer?.present(image) }
    }
}

@MainActor
final class CaptureController {
    private var stream: SCStream?
    private var mailbox: FrameMailbox?
    private var requestID = UUID()
    private var outputSize: CGSize?

    func start(window: SCWindow, renderer: MetalFrameView) async throws {
        let request = UUID()
        requestID = request
        await stopActiveStream()
        guard request == requestID else { return }
        let configuration = makeConfiguration(window: window, renderer: renderer)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                              configuration: configuration, delegate: nil)
        let mailbox = FrameMailbox(renderer: renderer)
        try stream.addStreamOutput(mailbox, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "org.dropy.capture.frames"))
        try await stream.startCapture()
        guard request == requestID else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        self.mailbox = mailbox
        self.outputSize = CGSize(width: configuration.width, height: configuration.height)
    }

    /// Keep capture resolution aligned with a resized source without tearing
    /// down the renderer or selecting a new window by title.
    func updateWindow(_ window: SCWindow, renderer: MetalFrameView) async throws {
        guard let stream else { return }
        let request = requestID
        let configuration = makeConfiguration(window: window, renderer: renderer)
        let nextSize = CGSize(width: configuration.width, height: configuration.height)
        guard nextSize != outputSize else { return }
        try await stream.updateConfiguration(configuration)
        guard request == requestID else { return }
        outputSize = nextSize
    }

    private func makeConfiguration(window: SCWindow, renderer: MetalFrameView) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let backingScale = renderer.window?.backingScaleFactor ?? 2
        let sourceWidth = max(window.frame.width, 1)
        let sourceHeight = max(window.frame.height, 1)
        let horizontalScale = renderer.bounds.width * backingScale / sourceWidth
        let verticalScale = renderer.bounds.height * backingScale / sourceHeight
        let requestedScale: CGFloat
        switch renderer.contentMode {
        case .fit, .selectedRegion: requestedScale = min(horizontalScale, verticalScale)
        case .fill: requestedScale = max(horizontalScale, verticalScale)
        case .nativeScale: requestedScale = backingScale
        }
        let captureScale = min(max(requestedScale, 0.1), backingScale)
        configuration.width = max(64, Int(sourceWidth * captureScale))
        configuration.height = max(64, Int(sourceHeight * captureScale))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.capturesAudio = false
        configuration.includeChildWindows = true
        return configuration
    }

    func stop() async {
        requestID = UUID()
        await stopActiveStream()
    }

    private func stopActiveStream() async {
        outputSize = nil
        guard let stream else { return }
        self.stream = nil
        self.mailbox = nil
        try? await stream.stopCapture()
    }
}
