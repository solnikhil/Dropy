import Foundation

/// Nearest-rank percentiles over millisecond samples.
public struct LatencySummary: Equatable, Sendable {
    public let count: Int
    public let p50: Double
    public let p95: Double
    public let p99: Double
    public let max: Double

    public init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func rank(_ p: Double) -> Double {
            sorted[Swift.min(sorted.count - 1, Swift.max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
        }
        count = sorted.count
        p50 = rank(0.50)
        p95 = rank(0.95)
        p99 = rank(0.99)
        self.max = sorted[sorted.count - 1]
    }

    public var text: String {
        String(format: "n=%d p50=%.1f p95=%.1f p99=%.1f max=%.1f", count, p50, p95, p99, max)
    }
}

/// Timestamps from two clocks can only be subtracted when they share a domain.
/// A domain is accepted when the measured offset between the clocks is negligible
/// and nearly every interval is non-negative and under one second.
public enum ClockDomainCheck {
    public static let maximumOffsetMilliseconds = 1.0
    public static let maximumPlausibleIntervalMilliseconds = 1_000.0
    public static let requiredPlausibleFraction = 0.99

    public static func accepts(offsetMilliseconds: Double, intervals: [Double]) -> Bool {
        guard abs(offsetMilliseconds) <= maximumOffsetMilliseconds, !intervals.isEmpty else {
            return false
        }
        let plausible = intervals.filter { $0 >= 0 && $0 <= maximumPlausibleIntervalMilliseconds }
        return Double(plausible.count) / Double(intervals.count) >= requiredPlausibleFraction
    }
}

/// One stream's measurements. It holds counts and timings only: no pixels,
/// titles, app names or text, so its summary is safe for default logs.
public struct CaptureSessionMetrics: Sendable {
    /// Samples beyond this are counted but not stored (about ten minutes at 60 fps).
    public static let sampleLimit = 36_000

    public var windowID: UInt32
    /// Milliseconds from the start request to `startCapture` returning.
    public var startMilliseconds: Double?
    /// Milliseconds from the start request to the first complete frame arriving.
    public var firstFrameMilliseconds: Double?
    public var width = 0
    public var height = 0
    public var pixelFormat = ""
    /// Frames by ScreenCaptureKit status, e.g. complete, idle, blank, suspended.
    public var statusCounts: [String: Int] = [:]
    /// Complete frames byte-identical to the last forwarded frame, skipped before rendering.
    public var unchanged = 0
    /// Switches to the low idle capture rate, and back to the full rate.
    public var idleRateSwitches = 0
    public var fullRateSwitches = 0
    /// Successful preview input that requested a return to full-rate capture.
    /// The actual configuration change is counted separately in fullRateSwitches.
    public var interactionWakeRequests = 0
    /// Complete frames replaced in the mailbox before the main thread took them.
    public var mailboxDrops = 0
    /// Frames the compositor reported as shown.
    public var presented = 0
    /// Frames handed to the renderer that were never shown, e.g. a superseded drawable.
    public var notPresented = 0
    /// Drawable attempts never shown, including attempts whose frame later succeeded.
    public var drawableMisses = 0
    /// Frame display time to delivery in Dropy's callback. Both are host mach time.
    public var captureToCallback: [Double] = []
    /// Callback to on-glass presentation. Host mach time against Core Animation time.
    public var callbackToPresent: [Double] = []
    /// Frame display time to on-glass presentation, per shown frame.
    public var frameAge: [Double] = []
    /// Measured offset between Core Animation time and converted mach time.
    public var presentClockOffsetMilliseconds = 0.0

    public init(windowID: UInt32) { self.windowID = windowID }

    public mutating func recordStatus(_ status: String) {
        statusCounts[status, default: 0] += 1
    }

    public mutating func recordCaptureToCallback(_ milliseconds: Double) {
        if captureToCallback.count < Self.sampleLimit { captureToCallback.append(milliseconds) }
    }

    public mutating func recordPresented(callbackToPresent: Double, frameAge: Double?) {
        presented += 1
        if self.callbackToPresent.count < Self.sampleLimit {
            self.callbackToPresent.append(callbackToPresent)
        }
        if let frameAge, self.frameAge.count < Self.sampleLimit {
            self.frameAge.append(frameAge)
        }
    }

    /// Percentiles are reported only for intervals whose clock domains passed the check.
    public func summary(durationSeconds: Double, stopReason: String) -> String {
        func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
        let statuses = statusCounts.keys.sorted().map { "\($0)=\(statusCounts[$0]!)" }
            .joined(separator: ",")
        let complete = statusCounts["complete"] ?? 0
        let rate = durationSeconds > 0 ? Double(complete) / durationSeconds : 0
        func latency(_ samples: [Double], offset: Double) -> String {
            guard ClockDomainCheck.accepts(offsetMilliseconds: offset, intervals: samples) else {
                return samples.isEmpty ? "none" : "unchecked-clock"
            }
            return LatencySummary(samples)?.text ?? "none"
        }
        return [
            "window=\(windowID)",
            String(format: "duration=%.1fs", durationSeconds),
            "start=\(ms(startMilliseconds))ms",
            "firstFrame=\(ms(firstFrameMilliseconds))ms",
            "output=\(width)x\(height)/\(pixelFormat.isEmpty ? "-" : pixelFormat)",
            "status=[\(statuses)]",
            String(format: "completeRate=%.1f/s", rate),
            "unchanged=\(unchanged)",
            "rateChanges=\(idleRateSwitches)idle/\(fullRateSwitches)full",
            "interactionWakeRequests=\(interactionWakeRequests)",
            "mailboxDrops=\(mailboxDrops)",
            "presented=\(presented)",
            "notPresented=\(notPresented)",
            "drawableMisses=\(drawableMisses)",
            "captureToCallback=[\(latency(captureToCallback, offset: 0))]",
            "callbackToPresent=[\(latency(callbackToPresent, offset: presentClockOffsetMilliseconds))]",
            "frameAge=[\(latency(frameAge, offset: presentClockOffsetMilliseconds))]",
            String(format: "clockOffset=%.3fms", presentClockOffsetMilliseconds),
            "stop=\(stopReason)",
        ].joined(separator: " ")
    }
}

/// A four-character code such as `BGRA`, for logs.
public func fourCharacterCode(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return String(value) }
    return String(decoding: bytes, as: UTF8.self)
}
