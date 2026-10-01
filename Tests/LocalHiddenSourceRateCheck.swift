import DropyCore
import Foundation

/// The app side of the hidden-source rate: the capture queue records changed frames
/// while the main actor changes the concealment and reads the verdict, so the holder
/// must lose nothing and never tear. Scripts/test-local.sh builds this check with the
/// thread sanitizer, which is what proves the lock is doing the work rather than the
/// timing being kind; the clock contract is checked in Tests/LocalFrameStampCheck.swift.
@main
struct LocalHiddenSourceRateCheck {
    static func main() {
        // Ten seconds of an animating source at 60 fps, as the capture queue sees it.
        let rate = HiddenSourceRate()
        for index in 0..<600 { rate.recordFrame(changed: true, at: Double(index) / 60) }
        precondition(rate.assessment(at: 10) == .notHidden, "nothing is hidden until Dropy hides it")
        // Parked: no pixel of the window is left, and its app falls to 5 fps.
        rate.setHidden(true, at: 10)
        for index in 0..<10 { rate.recordFrame(changed: true, at: 10.1 + Double(index) / 5) }
        guard case .slowedWhileHidden(let before, let hidden) = rate.assessment(at: 12) else {
            preconditionFailure("a hidden source that fell from 60 to 5 fps must be reported: " +
                                rate.assessment(at: 12).diagnosticName)
        }
        precondition(before == 60 && hidden == 5, "measured \(before) -> \(hidden) fps")
        precondition(HiddenSourceRateMonitor.label(rate.assessment(at: 12)) != nil)
        // A restore, or a tab uncovered: the claim goes with it.
        rate.setHidden(false, at: 12)
        precondition(rate.assessment(at: 12) == .notHidden, "showing the window clears the verdict")
        precondition(HiddenSourceRateMonitor.label(rate.assessment(at: 12)) == nil)

        // Unchanged frames feed neither measuring window. `FrameMailbox` offers every
        // frame it receives, so this rule is the holder's, not the call site's: a
        // ScreenCaptureKit stream keeps re-delivering identical frames for a window that
        // is not drawing, at the capture rate rather than the source's. Counted, they
        // would inflate the baseline before hiding and — the silent failure this check
        // exists for — fill the hidden window as well, so a source that fell from 60 to
        // 5 fps would read `.normal` and the preview would say nothing at all.
        let repeats = HiddenSourceRate()
        for index in 0..<600 {
            // 60 fps of stream frames, of which only every twelfth is the source's own
            // draw: 5 fps of real work, which is not an animating baseline.
            rate60(index, into: repeats, changedEvery: 12, from: 0)
        }
        repeats.setHidden(true, at: 10)
        precondition(repeats.assessment(at: 12) == .unknown,
                     "unchanged frames must not build a baseline: " + repeats.assessment(at: 12).diagnosticName)
        // Animating before, throttled to 5 fps while hidden, with the stream still
        // repeating the last frame 60 times a second. The frames run from just after the
        // moment of hiding to the moment of the verdict, which is the half-open window
        // the monitor measures: ten changed frames in two seconds are 5 fps.
        let throttled = HiddenSourceRate()
        for index in 0..<600 { throttled.recordFrame(changed: true, at: Double(index) / 60) }
        throttled.setHidden(true, at: 10)
        for index in 1...120 { rate60(index, into: throttled, changedEvery: 12, from: 10) }
        precondition(throttled.assessment(at: 12) == .slowedWhileHidden(before: 60, hidden: 5),
                     "unchanged frames must not fill the hidden window: " +
                     throttled.assessment(at: 12).diagnosticName)

        // Frames arriving on the capture queue while the main actor reads the verdict.
        // Frames sharing a timestamp are all kept, so a lost or torn write shows up as a
        // different measured rate: twenty frames in the two-second window are 10 fps.
        let raced = HiddenSourceRate()
        for index in 0..<600 { raced.recordFrame(changed: true, at: Double(index) / 60) }
        raced.setHidden(true, at: 10)
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            if index.isMultiple(of: 2) {
                raced.recordFrame(changed: true, at: 11)
            } else {
                _ = raced.assessment(at: 12)
            }
        }
        precondition(raced.assessment(at: 12) == .slowedWhileHidden(before: 60, hidden: 10),
                     "concurrent frames were lost: \(raced.assessment(at: 12).diagnosticName)")

        // The call shape the app uses: no time is passed anywhere, so the monitor's own
        // clock is the only one in play. A monitor with no frames behind it has no
        // baseline, so it judges nothing however long it stays hidden.
        let live = HiddenSourceRate()
        live.setHidden(true)
        precondition(live.assessment() == .unknown, "a monitor with no baseline judges nothing")
        live.setHidden(false)
        precondition(live.assessment() == .notHidden)
        print("Hidden source rate checks passed")
    }

    /// One frame of a 60 fps stream, changed only every `changedEvery`th frame — what
    /// the capture queue sees from a source drawing 60/`changedEvery` times a second.
    private static func rate60(_ index: Int, into rate: HiddenSourceRate,
                               changedEvery: Int, from start: TimeInterval) {
        rate.recordFrame(changed: index.isMultiple(of: changedEvery), at: start + Double(index) / 60)
    }
}
