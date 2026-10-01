import Darwin
import DropyCore
import Foundation

@main
struct LocalFrameStampCheck {
    static func main() {
        let recorder = CaptureMetricsRecorder(windowID: 1, requestedAt: HostClock.nowMilliseconds())
        let stamp = FrameStamp(displayMilliseconds: nil, callbackMilliseconds: HostClock.nowMilliseconds(), recorder: recorder)
        // The clock contract behind the hidden-source rate. The monitor is fed
        // `callbackMilliseconds / 1_000` from the capture queue and asked for a verdict at
        // `HiddenSourceRate.now()`, and only ever compares its times with each other. A
        // mixed epoch would not fail loudly: every measuring window would be empty and
        // the preview would simply go quiet forever. So four readings must be one clock:
        // a frame stamp, the clock the app reads, the mach epoch frame display times come
        // from, and the one function allowed to choose it. `stamp` above already paid for
        // the lazy timebase and tracing flag, so these readings are only work apart.
        let epochStamp = FrameStamp(displayMilliseconds: nil,
                                    callbackMilliseconds: HostClock.nowMilliseconds(), recorder: recorder)
        precondition(HiddenSourceRateMonitor.clocksAgree(epochStamp.callbackMilliseconds / 1_000,
                                                         HostClock.nowSeconds()),
                     "frame stamps and HostClock.nowSeconds() must share one epoch: " +
                     "\(epochStamp.callbackMilliseconds / 1_000) against \(HostClock.nowSeconds())")
        precondition(HiddenSourceRateMonitor.clocksAgree(HostClock.nowSeconds(),
                                                         HostClock.milliseconds(fromMach: mach_absolute_time()) / 1_000),
                     "HostClock must stay on the mach clock, which frame display times come from")
        precondition(HiddenSourceRateMonitor.clocksAgree(HiddenSourceRate.now(), HostClock.nowSeconds()),
                     "HiddenSourceRate.now() must be the frame clock: " +
                     "\(HiddenSourceRate.now()) against \(HostClock.nowSeconds())")
        // Multiple failed attempts do not finalize a frame that can still be retried.
        recorder.recordPresented(stamp, presentedTime: 0)
        recorder.recordPresented(stamp, presentedTime: 0)
        precondition(stamp.claimFinalOutcome())
        precondition(!stamp.claimFinalOutcome())
        let shown = FrameStamp(displayMilliseconds: nil, callbackMilliseconds: HostClock.nowMilliseconds(), recorder: recorder)
        recorder.recordPresented(shown, presentedTime: ProcessInfo.processInfo.systemUptime)
        recorder.recordPresented(shown, presentedTime: ProcessInfo.processInfo.systemUptime)
        recorder.recordNotPresented(shown)
        precondition(recorder.counts().presented == 1, "duplicate callbacks count a frame only once")
        let raced = FrameStamp(displayMilliseconds: nil, callbackMilliseconds: 0, recorder: recorder)
        let lock = NSLock()
        nonisolated(unsafe) var accepted = 0
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if raced.claimFinalOutcome() { lock.withLock { accepted += 1 } }
        }
        precondition(accepted == 1, "presentation/drop callbacks must finalize a frame only once")
        print("Frame outcome checks passed")
    }
}
