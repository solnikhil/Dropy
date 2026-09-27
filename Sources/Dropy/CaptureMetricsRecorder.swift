import CoreMedia
import CoreVideo
import DropyCore
import Foundation
import QuartzCore
import ScreenCaptureKit

/// Host time helpers. ScreenCaptureKit's `displayTime` and `mach_absolute_time`
/// share the mach clock; Core Animation's media time is checked against it at runtime.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func milliseconds(fromMach value: UInt64) -> Double {
        Double(value) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    static func nowMilliseconds() -> Double { milliseconds(fromMach: mach_absolute_time()) }

    /// Core Animation media time minus converted mach time, taking the tightest of
    /// several paired reads.
    static func coreAnimationOffsetMilliseconds() -> Double {
        (0..<5).map { _ -> Double in
            let before = nowMilliseconds()
            let media = CACurrentMediaTime() * 1_000
            let after = nowMilliseconds()
            return media - (before + after) / 2
        }.min { abs($0) < abs($1) } ?? .infinity
    }
}

/// Carries one complete frame's timestamps from the capture callback to presentation.
struct FrameStamp: Sendable {
    let displayMilliseconds: Double?
    let callbackMilliseconds: Double
    let recorder: CaptureMetricsRecorder
}

/// Thread-safe per-stream metrics. The capture queue, the main thread and Metal's
/// presentation callbacks all report here; the summary is logged once at stop.
final class CaptureMetricsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: CaptureSessionMetrics
    private let requestedAt: Double
    private var startedAt: Double?
    private var finished = false

    init(windowID: UInt32, requestedAt: Double) {
        metrics = CaptureSessionMetrics(windowID: windowID)
        metrics.presentClockOffsetMilliseconds = HostClock.coreAnimationOffsetMilliseconds()
        self.requestedAt = requestedAt
    }

    func startReturned() {
        let now = HostClock.nowMilliseconds()
        lock.withLock {
            startedAt = now
            metrics.startMilliseconds = now - requestedAt
        }
    }

    /// Records a frame's status; returns a stamp for complete frames with an image.
    func recordFrame(_ sampleBuffer: CMSampleBuffer, image: CVPixelBuffer?) -> FrameStamp? {
        let callback = HostClock.nowMilliseconds()
        let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first
        let status = (info?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        let display = (info?[.displayTime] as? UInt64).map(HostClock.milliseconds(fromMach:))
        return lock.withLock {
            metrics.recordStatus(status.map(Self.name) ?? "unknown")
            guard status == .complete, let image else { return nil }
            if metrics.firstFrameMilliseconds == nil {
                metrics.firstFrameMilliseconds = callback - requestedAt
                metrics.width = CVPixelBufferGetWidth(image)
                metrics.height = CVPixelBufferGetHeight(image)
                metrics.pixelFormat = fourCharacterCode(CVPixelBufferGetPixelFormatType(image))
            }
            if let display { metrics.recordCaptureToCallback(callback - display) }
            return FrameStamp(displayMilliseconds: display, callbackMilliseconds: callback,
                              recorder: self)
        }
    }

    func recordMailboxDrop() { lock.withLock { metrics.mailboxDrops += 1 } }

    /// `presentedTime` is Core Animation media time in seconds, or zero when the
    /// compositor never showed the drawable.
    func recordPresented(_ stamp: FrameStamp, presentedTime: CFTimeInterval) {
        lock.withLock {
            guard presentedTime > 0 else {
                metrics.notPresented += 1
                return
            }
            let presented = presentedTime * 1_000 - metrics.presentClockOffsetMilliseconds
            metrics.recordPresented(
                callbackToPresent: presented - stamp.callbackMilliseconds,
                frameAge: stamp.displayMilliseconds.map { presented - $0 })
        }
    }

    func recordNotPresented() { lock.withLock { metrics.notPresented += 1 } }

    /// Logs the summary once. Later calls, e.g. a second stop path, are ignored.
    func finish(reason: String) {
        let line: String? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let duration = (HostClock.nowMilliseconds() - (startedAt ?? requestedAt)) / 1_000
            return metrics.summary(durationSeconds: duration, stopReason: reason)
        }
        if let line { NSLog("Dropy capture metrics: %@", line) }
    }

    private static func name(_ status: SCFrameStatus) -> String {
        switch status {
        case .complete: "complete"
        case .idle: "idle"
        case .blank: "blank"
        case .suspended: "suspended"
        case .started: "started"
        case .stopped: "stopped"
        @unknown default: "other"
        }
    }
}
