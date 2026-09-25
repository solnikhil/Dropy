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
    private var invalidated = false
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
        guard !invalidated else { lock.unlock(); return }
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

    /// Drop the pending frame and refuse later ones, so a stopped or superseded
    /// stream can never repaint the preview after it was cleared.
    func invalidate() {
        lock.lock()
        invalidated = true
        latest = nil
        lock.unlock()
    }

    @MainActor private func deliverLatest() {
        lock.lock()
        let image = invalidated ? nil : latest
        latest = nil
        scheduled = false
        lock.unlock()
        if let image { renderer?.present(image) }
    }
}

/// Reports a stream that stopped without Dropy asking, such as a revoked permission,
/// the system screen-sharing control, or the source app going away.
final class StreamStopObserver: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onStop: @Sendable (Error) -> Void

    init(onStop: @escaping @Sendable (Error) -> Void) { self.onStop = onStop }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop(error) }
}

@MainActor
final class CaptureController {
    private var stream: SCStream?
    private var mailbox: FrameMailbox?
    private var stopObserver: StreamStopObserver?
    private var requestID = UUID()
    private var outputSize: CGSize?

    /// Starts one stream. `onUnexpectedStop` runs on the main actor only while this
    /// stream is still the active one; a stop Dropy requested is never reported.
    /// Returns false when a newer start or a stop superseded this request.
    @discardableResult
    func start(window: SCWindow, renderer: MetalFrameView,
               onUnexpectedStop: @escaping @MainActor (Error) -> Void) async throws -> Bool {
        let request = UUID()
        requestID = request
        await stopActiveStream()
        guard request == requestID else { return false }
        let configuration = makeConfiguration(window: window, renderer: renderer)
        let observer = StreamStopObserver { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == request, self.stream != nil else { return }
                let code = (error as NSError).code
                NSLog("Dropy capture stopped unexpectedly: domain=%@ code=%ld",
                      (error as NSError).domain, code)
                let stopped = self.detachActiveStream()
                onUnexpectedStop(error)
                try? await stopped?.stopCapture()
            }
        }
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                              configuration: configuration, delegate: observer)
        let mailbox = FrameMailbox(renderer: renderer)
        try stream.addStreamOutput(mailbox, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "org.dropy.capture.frames"))
        do {
            try await stream.startCapture()
        } catch {
            mailbox.invalidate()
            throw error
        }
        guard request == requestID else {
            mailbox.invalidate()
            try? await stream.stopCapture()
            return false
        }
        self.stream = stream
        self.mailbox = mailbox
        self.stopObserver = observer
        self.outputSize = CGSize(width: configuration.width, height: configuration.height)
        return true
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
        try? await detachActiveStream()?.stopCapture()
    }

    /// Forget the active stream synchronously, so no later callback treats it as current.
    private func detachActiveStream() -> SCStream? {
        outputSize = nil
        mailbox?.invalidate()
        mailbox = nil
        stopObserver = nil
        defer { stream = nil }
        return stream
    }
}
