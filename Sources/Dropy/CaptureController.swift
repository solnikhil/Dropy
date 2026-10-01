import AppKit
import CoreMedia
import CoreVideo
import DropyCore
import IOSurface
import ScreenCaptureKit

/// The stream callback only replaces a bounded latest-frame slot. Rendering runs
/// on the main thread; an overloaded UI drops stale frames instead of queueing them.
final class FrameMailbox: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    let confirmation = CaptureConfirmation()
    private var latest: (image: CVPixelBuffer, stamp: FrameStamp, geometry: CaptureGeometry?)?
    /// The stream configuration frames are currently produced with; attached to each
    /// forwarded frame so preview input can prove which window and size it shows.
    private var geometry: CaptureGeometry?
    /// The last frame sent toward the renderer, kept to detect unchanged frames.
    private var lastForwarded: CVPixelBuffer?
    private var lastForwardedGeometry: CaptureGeometry?
    private var diagnosticFrames = 0
    private let logsGeometry = ProcessInfo.processInfo.environment["DROPY_DEBUG_FRAME_GEOMETRY"] == "1"
    private var scheduled = false
    private var invalidated = false
    private weak var renderer: MetalFrameView?
    let metrics: CaptureMetricsRecorder
    /// Consecutive unchanged frames before the source counts as idle (0.5 s at 60 fps).
    static let idleThreshold = CaptureActivityTracker.defaultUnchangedThreshold
    private var activity = CaptureActivityTracker()
    private var activitySequence = 0
    private let hiddenRate: HiddenSourceRate
    /// Activity mutations share the serial stream callback queue.
    private let sampleHandlerQueue: DispatchQueue
    private let onActivityChange: @Sendable (Bool, Int) -> Void

    init(renderer: MetalFrameView, metrics: CaptureMetricsRecorder, hiddenRate: HiddenSourceRate,
         sampleHandlerQueue: DispatchQueue,
         onActivityChange: @escaping @Sendable (Bool, Int) -> Void) {
        self.renderer = renderer
        self.metrics = metrics
        self.hiddenRate = hiddenRate
        self.sampleHandlerQueue = sampleHandlerQueue
        self.onActivityChange = onActivityChange
    }

    /// Only successful input reaches this method. Serializing it with sample
    /// callbacks preserves activity ordering and their sequence numbers.
    func noteInteraction() {
        sampleHandlerQueue.async { [self] in
            lock.lock()
            let active = !invalidated
            lock.unlock()
            guard active else { return }
            if activity.resumeForInteraction() {
                metrics.recordInteractionWakeRequest()
                activitySequence += 1
                onActivityChange(false, activitySequence)
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        lock.lock()
        let previous = invalidated ? nil : lastForwarded
        let configuredGeometry = geometry
        let previousGeometry = lastForwardedGeometry
        let active = !invalidated
        lock.unlock()
        guard active else { return }
        let statusInfo = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first
        if (statusInfo?[.status] as? Int) == SCFrameStatus.idle.rawValue {
            confirmation.observe(changed: false, at: HostClock.nowMilliseconds())
        }
        guard let stamp = metrics.recordFrame(sampleBuffer,
                                              image: CMSampleBufferGetImageBuffer(sampleBuffer)),
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Unchanged content skips the main-thread handoff, the draw and the
        // compositor work entirely. The comparison runs outside the lock; stream
        // callbacks are serial, so only this queue writes `lastForwarded`.
        // Geometry must come from this sample's metadata, not the moment at which
        // updateConfiguration happened to finish. Old-size frames can arrive later,
        // including when a proportional resize leaves the output dimensions unchanged.
        let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first
        let rect = (info?[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        let scale = info?[.contentScale] as? CGFloat
        let density = info?[.scaleFactor] as? CGFloat
        let measuredGeometry = configuredGeometry.flatMap { config in
            CaptureGeometry.measured(configured: config, contentRect: rect, contentScale: scale,
                                     scaleFactor: density)
        }
        if logsGeometry, diagnosticFrames < 6 {
            diagnosticFrames += 1
            NSLog("Dropy frame geometry: rect=%@ contentScale=%@ density=%@ configured=%@ measured=%@",
                  String(describing: rect), String(describing: scale), String(describing: density),
                  String(describing: configuredGeometry), String(describing: measuredGeometry))
        }
        let unchanged = previous.map { previousGeometry == measuredGeometry && Self.identical($0, image) } ?? false
        if let idle = activity.record(unchanged: unchanged) {
            activitySequence += 1
            onActivityChange(idle, activitySequence)
        }
        stamp.captureRevision = confirmation.observe(changed: !unchanged, at: HostClock.nowMilliseconds())
        // Every frame is offered to the rate, changed or not: which ones count is the
        // holder's rule (`HiddenSourceRate.recordFrame`), checked by
        // Tests/LocalHiddenSourceRateCheck.swift, not something this call site decides
        // by standing after an early return. The frame's callback time is already on the
        // monotonic mach clock.
        hiddenRate.recordFrame(changed: !unchanged, at: stamp.callbackMilliseconds / 1_000)
        if unchanged {
            metrics.recordUnchanged()
            return
        }
        stamp.mark { $0.compared = $1 }
        lock.lock()
        guard !invalidated else { lock.unlock(); return }
        lastForwarded = image
        lastForwardedGeometry = measuredGeometry
        if latest != nil { metrics.recordMailboxDrop() }
        latest = (image, stamp, measuredGeometry)
        stamp.mark { $0.forwarded = $1 }
        let shouldSchedule = !scheduled
        if shouldSchedule { scheduled = true }
        lock.unlock()
        if shouldSchedule { DispatchQueue.main.async { self.deliverLatest() } }
    }

    func setGeometry(_ next: CaptureGeometry) {
        lock.lock()
        geometry = next
        lock.unlock()
    }

    /// Drop the pending frame and refuse later ones, so a stopped or superseded
    /// stream can never repaint the preview after it was cleared.
    func invalidate() {
        lock.lock()
        invalidated = true
        confirmation.invalidate()
        latest = nil
        lastForwarded = nil
        lock.unlock()
    }

    @MainActor private func deliverLatest() {
        lock.lock()
        let frame = invalidated ? nil : latest
        latest = nil
        scheduled = false
        lock.unlock()
        if let frame {
            frame.stamp.mark { $0.delivered = $1 }
            renderer?.present(frame.image, stamp: frame.stamp, geometry: frame.geometry)
        }
    }
}

extension FrameMailbox {
    static func identical(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(first), height = CVPixelBufferGetHeight(first)
        guard width <= Int.max / 4,
              width == CVPixelBufferGetWidth(second), height == CVPixelBufferGetHeight(second),
              CVPixelBufferGetPixelFormatType(first) == CVPixelBufferGetPixelFormatType(second),
              CVPixelBufferGetPixelFormatType(first) == kCVPixelFormatType_32BGRA else { return false }
        guard CVPixelBufferLockBaseAddress(first, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(first, .readOnly) }
        guard CVPixelBufferLockBaseAddress(second, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(second, .readOnly) }
        guard let a = CVPixelBufferGetBaseAddress(first),
              let b = CVPixelBufferGetBaseAddress(second) else { return false }
        return FrameComparison.identical(a, rowStride: CVPixelBufferGetBytesPerRow(first),
                                         b, rowStride: CVPixelBufferGetBytesPerRow(second),
                                         bytesPerRow: width * 4, rows: height)
    }
}

/// Reports a stream that stopped without Dropy asking, such as a revoked permission,
/// the system screen-sharing control, or the source app going away.
final class StreamStopObserver: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onStop: @Sendable (SCStream, Error) -> Void

    init(onStop: @escaping @Sendable (SCStream, Error) -> Void) { self.onStop = onStop }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop(stream, error) }
}

enum CaptureStartError: Error { case previousStreamStopping }

@MainActor
final class CaptureController {
    /// Everything about a configuration that decides which pixels arrive: the surface to
    /// fill, the crop to fill it from, and the region that crop came from.
    ///
    /// Kept as one value so a rate change cannot quietly resize the stream, and so a
    /// reconfiguration can be skipped only when nothing about the pixels changed. Comparing
    /// output size alone was not enough once a crop existed: a proportional resize, or
    /// switching regions, can leave the surface the same size while the crop moves.
    private struct CaptureShape: Equatable {
        var windowID: UInt32
        var windowSize: CGSize
        var pixelSize: CGSize
        var region: NormalizedRegion?

        var geometry: CaptureGeometry {
            CaptureGeometry(windowID: windowID, windowSize: windowSize, pixelSize: pixelSize, crop: region)
        }
    }

    private var stream: SCStream?
    private var mailbox: FrameMailbox?
    /// The active stream's changed-frame rate monitor; nil when nothing is capturing.
    private var hiddenRate: HiddenSourceRate?
    private var stopObserver: StreamStopObserver?
    private var requestID = UUID()
    /// The shape the live stream is configured with, or nil when no stream is active.
    private var appliedShape: CaptureShape?
    /// Keep stopped streams in the count until ScreenCaptureKit confirms a stop.
    /// Retaining a failed stop also keeps it available for diagnosis.
    private var runningStreams: [ObjectIdentifier: (stream: SCStream, windowID: UInt32, observer: StreamStopObserver)] = [:]
    private var stopRetries: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopping: Set<ObjectIdentifier> = []
    private var recorders: [ObjectIdentifier: CaptureMetricsRecorder] = [:]
    private var captureIdle = false
    private var desiredIdle = false
    private var latestActivitySequence = 0
    private var rateRetryScheduled = false
    private var configurationBusy = false
    private var configurationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Starts one stream. `onUnexpectedStop` runs on the main actor only while this
    /// stream is still the active one; a stop Dropy requested is never reported.
    /// `crop` is the region mode's selection, or nil to capture the whole window.
    /// Returns false when a newer start or a stop superseded this request.
    @discardableResult
    func start(window: SCWindow, renderer: MetalFrameView, crop: NormalizedRegion?,
               onUnexpectedStop: @escaping @MainActor (Error) -> Void) async throws -> Bool {
        let request = UUID()
        let requestedAt = HostClock.nowMilliseconds()
        requestID = request
        await stopActiveStream(reason: "replaced")
        guard request == requestID else { return false }
        guard runningStreams.isEmpty else { throw CaptureStartError.previousStreamStopping }
        let shape = shape(window: window, renderer: renderer, crop: crop)
        let configuration = makeConfiguration(shape)
        let observer = StreamStopObserver { [weak self] stoppedStream, error in
            let stoppedID = ObjectIdentifier(stoppedStream)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopRetries.removeValue(forKey: stoppedID)?.cancel()
                self.runningStreams.removeValue(forKey: stoppedID)
                self.recorders.removeValue(forKey: stoppedID)?.finish(reason: "systemStopped")
                guard self.requestID == request, self.stream.map(ObjectIdentifier.init) == stoppedID else { return }
                let code = (error as NSError).code
                NSLog("Dropy capture stopped unexpectedly: domain=%@ code=%ld",
                      (error as NSError).domain, code)
                _ = self.detachActiveStream()
                onUnexpectedStop(error)

            }
        }
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                              configuration: configuration, delegate: observer)
        let recorder = CaptureMetricsRecorder(windowID: window.windowID, requestedAt: requestedAt)
        let hiddenRate = HiddenSourceRate()
        let sampleHandlerQueue = DispatchQueue(label: "org.dropy.capture.frames")
        let mailbox = FrameMailbox(renderer: renderer, metrics: recorder, hiddenRate: hiddenRate,
                                   sampleHandlerQueue: sampleHandlerQueue) { [weak self] idle, sequence in
            Task { @MainActor [weak self] in
                await self?.setSourceIdle(idle, sequence: sequence, request: request)
            }
        }
        do {
            try stream.addStreamOutput(mailbox, type: .screen,
                                       sampleHandlerQueue: sampleHandlerQueue)
        } catch {
            recorder.finish(reason: "startFailed(\((error as NSError).code))")
            throw error
        }
        mailbox.setGeometry(shape.geometry)
        recorders[ObjectIdentifier(stream)] = recorder
        // The delegate can stop a stream before startCapture returns. Publish
        // this session first so that an early stop is not silently discarded.
        self.stream = stream
        self.mailbox = mailbox
        self.hiddenRate = hiddenRate
        self.stopObserver = observer
        self.appliedShape = shape
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
        runningStreams[ObjectIdentifier(stream)] = (stream, window.windowID, observer)
        NSLog("Dropy capture started: window=%u running=%ld", window.windowID, runningStreams.count)
        return true
    }

    /// Keep capture resolution and any region crop aligned with a resized source without
    /// tearing down the renderer or selecting a new window by title.
    func updateWindow(_ window: SCWindow, renderer: MetalFrameView, crop: NormalizedRegion?) async throws {
        guard let stream else { return }
        let request = requestID
        await acquireConfiguration()
        defer { releaseConfiguration() }
        guard request == requestID, self.stream === stream else { return }
        let next = shape(window: window, renderer: renderer, crop: crop)
        guard next != appliedShape else {
            // Nothing about the pixels changed, so the stream keeps running. The window may
            // still have moved or been re-measured at the same size, which the geometry says.
            mailbox?.setGeometry(next.geometry)
            appliedShape = next
            return
        }
        try await stream.updateConfiguration(makeConfiguration(next))
        guard request == requestID else { return }
        // Frames drawn before this point keep the old output size, which the preview
        // input gate rejects against the new geometry.
        mailbox?.setGeometry(next.geometry)
        appliedShape = next
    }

    /// While the source is unchanged, capture at a low rate; sustained changes
    /// restore the full rate. Every changed frame still reaches the renderer immediately. ScreenCaptureKit keeps producing identical frames for
    /// titled windows, so without this an idle source costs as much as a live one.
    private func setSourceIdle(_ idle: Bool, sequence: Int, request: UUID) async {
        guard request == requestID, stream != nil,
              sequence > latestActivitySequence else { return }
        latestActivitySequence = sequence
        desiredIdle = idle
        await reconcileRate(request: request)
    }

    private func reconcileRate(request: UUID) async {
        await acquireConfiguration()
        defer { releaseConfiguration() }
        guard request == requestID, let stream, let shape = appliedShape,
              desiredIdle != captureIdle else { return }
        let targetIdle = desiredIdle
        // The same shape, only a different frame interval: a rate change must never
        // resize the stream or move its crop.
        do {
            try await stream.updateConfiguration(makeConfiguration(shape, idle: targetIdle))
        } catch {
            guard request == requestID else { return }
            NSLog("Dropy capture rate update failed: code=%ld", (error as NSError).code)
            scheduleRateRetry(request: request)
            return
        }
        guard request == requestID, self.stream === stream else { return }
        captureIdle = targetIdle
        mailbox?.metrics.recordRateChange(idle: targetIdle)
        if desiredIdle != targetIdle {
            Task { await reconcileRate(request: request) }
        }
    }

    private func scheduleRateRetry(request: UUID) {
        guard !rateRetryScheduled else { return }
        rateRetryScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, request == self.requestID else { return }
            self.rateRetryScheduled = false
            await self.reconcileRate(request: request)
        }
    }

    private func acquireConfiguration() async {
        if !configurationBusy {
            configurationBusy = true
            return
        }
        await withCheckedContinuation { configurationWaiters.append($0) }
    }

    private func releaseConfiguration() {
        if configurationWaiters.isEmpty {
            configurationBusy = false
        } else {
            configurationWaiters.removeFirst().resume()
        }
    }

    private static func frameInterval(idle: Bool) -> CMTime {
        CMTime(value: 1, timescale: idle ? 10 : 60)
    }

    /// Single-window capture always delivers the whole window: ScreenCaptureKit ignores
    /// sourceRect for this filter. Request enough full-window pixels for the region,
    /// then crop in Metal without a CPU image copy.
    private func shape(window: SCWindow, renderer: MetalFrameView,
                       crop: NormalizedRegion?) -> CaptureShape {
        let backingScale = renderer.window?.backingScaleFactor ?? 2
        let windowSize = CGSize(width: max(window.frame.width, 1), height: max(window.frame.height, 1))
        if let crop, let plan = RegionSelection.crop(region: crop, windowSize: windowSize,
                                                    previewSize: renderer.bounds.size,
                                                    backingScale: backingScale) {
            return CaptureShape(windowID: window.windowID, windowSize: window.frame.size,
                                pixelSize: RegionSelection.fullSurface(region: crop, plan: plan,
                                    windowSize: windowSize, backingScale: backingScale), region: crop)
        }
        let horizontalScale = renderer.bounds.width * backingScale / windowSize.width
        let verticalScale = renderer.bounds.height * backingScale / windowSize.height
        let requestedScale: CGFloat
        switch renderer.contentMode {
        // With no crop to show, region mode asks for the same pixels as fit.
        case .fit, .selectedRegion: requestedScale = min(horizontalScale, verticalScale)
        case .fill: requestedScale = max(horizontalScale, verticalScale)
        case .nativeScale: requestedScale = backingScale
        }
        let captureScale = min(max(requestedScale, RegionSelection.minimumCaptureScale), backingScale)
        let pixels = CGSize(width: max(RegionSelection.minimumCropPixelSide, (windowSize.width * captureScale).rounded(.down)),
                            height: max(RegionSelection.minimumCropPixelSide, (windowSize.height * captureScale).rounded(.down)))
        return CaptureShape(windowID: window.windowID, windowSize: window.frame.size,
                            pixelSize: pixels, region: nil)
    }

    private func makeConfiguration(_ shape: CaptureShape, idle: Bool? = nil) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(shape.pixelSize.width)
        configuration.height = Int(shape.pixelSize.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = Self.frameInterval(idle: idle ?? captureIdle)
        // One surface stays retained for unchanged-frame comparison, so allow one
        // more than the renderer and mailbox need.
        configuration.queueDepth = 4
        configuration.capturesAudio = false
        configuration.includeChildWindows = true
        return configuration
    }

    /// Totals for the active stream, if any.
    func currentCounts() -> CaptureCounts? { mailbox?.metrics.counts() }

    /// Dropy's containment now hides every pixel of the source, or no longer does. The
    /// monitor belongs to the active stream, so there is nothing to tell without one.
    /// The time comes from the monitor's own clock; no clock is chosen here.
    func setSourceHidden(_ hidden: Bool) {
        hiddenRate?.setHidden(hidden)
    }

    /// What the changed-frame rate says about a source Dropy hid.
    func hiddenSourceAssessment() -> HiddenSourceRateMonitor.Assessment {
        hiddenRate?.assessment() ?? .notHidden
    }

    /// An input result may arrive after a source switch. Never wake another
    /// window's stream on behalf of the former selection.
    func noteInteraction(for windowID: UInt32) {
        guard appliedShape?.windowID == windowID else { return }
        mailbox?.noteInteraction()
    }

    /// `reason` is a log-safe label such as `closed` or a failure's diagnostic name.
    func stop(reason: String = "requested") async {
        requestID = UUID()
        await stopActiveStream(reason: reason)
    }

    private func stopActiveStream(reason: String) async {
        await stopCapture(detachActiveStream(), reason: reason)
    }

    func inputFrameIsCurrent(_ renderer: MetalFrameView) -> Bool {
        mailbox?.confirmation.permits(revision: renderer.drawnCaptureRevision,
                                      at: HostClock.nowMilliseconds()) == true
    }

    private func stopCapture(_ stream: SCStream?, reason: String, attempt: Int = 0) async {
        guard let stream else { return }
        let id = ObjectIdentifier(stream)
        guard stopping.insert(id).inserted else { return }
        defer { stopping.remove(id) }
        do {
            try await stream.stopCapture()
            stopRetries.removeValue(forKey: id)?.cancel()
            recorders.removeValue(forKey: id)?.finish(reason: reason)
            if let stopped = runningStreams.removeValue(forKey: id) {
                NSLog("Dropy capture stopped: window=%u running=%ld",
                      stopped.windowID, runningStreams.count)
            }
        } catch {
            let code = (error as NSError).code
            // Keep metrics and the stream until a stop succeeds. Retry with bounded
            // backoff; failure must never be reported as a completed stop.
            if runningStreams[id] != nil, stopRetries[id] == nil {
                stopRetries[id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(RecoveryBackoff.delay(afterAttempt: attempt)))
                    guard !Task.isCancelled, let self else { return }
                    self.stopRetries[id] = nil
                    await self.stopCapture(stream, reason: reason, attempt: attempt + 1)
                }
            }
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
        appliedShape = nil
        captureIdle = false
        desiredIdle = false
        latestActivitySequence = 0
        rateRetryScheduled = false
        mailbox?.invalidate()
        mailbox = nil
        // Dropping the monitor with its stream is the reset for a source switch or a
        // stop: an invalidated mailbox forwards nothing, and the next stream builds its
        // own baseline.
        hiddenRate = nil
        stopObserver = nil
        defer { stream = nil }
        return stream
    }
}
