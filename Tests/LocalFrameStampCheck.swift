import Foundation

@main
struct LocalFrameStampCheck {
    static func main() {
        let recorder = CaptureMetricsRecorder(windowID: 1, requestedAt: HostClock.nowMilliseconds())
        let stamp = FrameStamp(displayMilliseconds: nil, callbackMilliseconds: HostClock.nowMilliseconds(), recorder: recorder)
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
