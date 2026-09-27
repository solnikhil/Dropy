import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import ScreenCaptureKit

/// The stream callback only replaces a bounded latest-frame slot. Rendering runs
/// on the main thread; an overloaded UI drops stale frames instead of queueing them.
final class FrameMailbox: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (image: CVPixelBuffer, stamp: FrameStamp)?
    private var scheduled = false
    private var invalidated = false
    private weak var renderer: MetalFrameView?
    let metrics: CaptureMetricsRecorder

    init(renderer: MetalFrameView, metrics: CaptureMetricsRecorder) {
        self.renderer = renderer
        self.metrics = metrics
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        lock.lock()
        guard !invalidated else { lock.unlock(); return }
        guard let stamp = metrics.recordFrame(sampleBuffer,
                                              image: CMSampleBufferGetImageBuffer(sampleBuffer)),
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            lock.unlock()
            return
        }
        if latest != nil { metrics.recordMailboxDrop() }
        latest = (image, stamp)
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
        let frame = invalidated ? nil : latest
        latest = nil
        scheduled = false
        lock.unlock()
        if let frame { renderer?.present(frame.image, stamp: frame.stamp) }
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
    /// Keep stopped streams in the count until ScreenCaptureKit confirms a stop.
    /// Retaining a failed stop also keeps it available for diagnosis.
    private var runningStreams: [ObjectIdentifier: (stream: SCStream, windowID: UInt32)] = [:]
    private var recorders: [ObjectIdentifier: CaptureMetricsRecorder] = [:]

    /// Starts one stream. `onUnexpectedStop` runs on the main actor only while this
    /// stream is still the active one; a stop Dropy requested is never reported.
    /// Returns false when a newer start or a stop superseded this request.
    @discardableResult
    func start(window: SCWindow, renderer: MetalFrameView,
               onUnexpectedStop: @escaping @MainActor (Error) -> Void) async throws -> Bool {
        let request = UUID()
        let requestedAt = HostClock.nowMilliseconds()
        requestID = request
        await stopActiveStream(reason: "replaced")
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
                await self.stopCapture(stopped, reason: "unexpected(\(code))")
            }
        }
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                              configuration: configuration, delegate: observer)
        let recorder = CaptureMetricsRecorder(windowID: window.windowID, requestedAt: requestedAt)
        let mailbox = FrameMailbox(renderer: renderer, metrics: recorder)
        do {
            try stream.addStreamOutput(mailbox, type: .screen,
                                       sampleHandlerQueue: DispatchQueue(label: "org.dropy.capture.frames"))
        } catch {
            recorder.finish(reason: "startFailed(\((error as NSError).code))")
            throw error
        }
        recorders[ObjectIdentifier(stream)] = recorder
        // The delegate can stop a stream before startCapture returns. Publish
        // this session first so that an early stop is not silently discarded.
        self.stream = stream
        self.mailbox = mailbox
        self.stopObserver = observer
        self.outputSize = CGSize(width: configuration.width, height: configuration.height)
        do {
            try await stream.startCapture()
            recorder.startReturned()
        } catch {
            mailbox.invalidate()
            recorders.removeValue(forKey: ObjectIdentifier(stream))?
                .finish(reason: "startFailed(\((error as NSError).code))")
            guard request == requestID, self.stream === stream else { return false }
            _ = detachActiveStream()
            throw error
        }
        guard request == requestID, self.stream === stream else {
            mailbox.invalidate()
            await stopCapture(stream, reason: "replaced")
            return false
        }
        runningStreams[ObjectIdentifier(stream)] = (stream, window.windowID)
        NSLog("Dropy capture started: window=%u running=%ld", window.windowID, runningStreams.count)
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

    /// `reason` is a log-safe label such as `closed` or a failure's diagnostic name.
    func stop(reason: String = "requested") async {
        requestID = UUID()
        await stopActiveStream(reason: reason)
    }

    private func stopActiveStream(reason: String) async {
        await stopCapture(detachActiveStream(), reason: reason)
    }

    private func stopCapture(_ stream: SCStream?, reason: String) async {
        guard let stream else { return }
        let id = ObjectIdentifier(stream)
        do {
            try await stream.stopCapture()
            recorders.removeValue(forKey: id)?.finish(reason: reason)
            if let stopped = runningStreams.removeValue(forKey: id) {
                NSLog("Dropy capture stopped: window=%u running=%ld",
                      stopped.windowID, runningStreams.count)
            }
        } catch {
            let code = (error as NSError).code
            recorders.removeValue(forKey: id)?.finish(reason: "stopFailed(\(code))")
            if let entry = runningStreams[id] {
                NSLog("Dropy capture stop failed: window=%u code=%ld running=%ld",
                      entry.windowID, code, runningStreams.count)
            } else {
                NSLog("Dropy capture stop failed: code=%ld running=%ld", code, runningStreams.count)
            }
        }
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
