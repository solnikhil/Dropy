/// Whether Dropy may capture the screen now. Any ScreenCaptureKit stream or
/// screenshot, even of a single other window for a fraction of a second, tells every
/// app on the Mac that the screen is being recorded (WindowServer logs "screen capture
/// added"; iPad-style apps see `UIScreen.isCaptured`). Video players such as Prime
/// Video stop playing when they hear it. So docking a window captures nothing, and
/// the two modes that must stream (the live preview, and Live over a full-screen app)
/// first ask this.
public enum CaptureGuard {
    /// Bundle identifiers, each observed stopping playback when Dropy captured. They
    /// count while open, even paused. Prime Video: 2026-10-11, on opening and closing a
    /// docked window (two screenshots of 20–50 ms each).
    public static let sensitiveBundleIdentifiers: Set<String> = [
        "com.amazon.aiv.AIVApp",
    ]

    /// The first running app (bundle identifier, name) that capture would interrupt.
    public static func blocker(in running: [(bundleIdentifier: String?, name: String?)]) -> String? {
        running.first { $0.bundleIdentifier.map(sensitiveBundleIdentifiers.contains) ?? false }
            .map { $0.name ?? "A video app" }
    }

    /// Power assertion types that keep the display on. Video players take one while
    /// they play (AVPlayer does by default, browsers for a playing video).
    public static let displayAwakeTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// The processes keeping the display awake, from `IOPMCopyAssertionsByProcess`
    /// (process id → that process's assertions). An assertion made on behalf of another
    /// process counts for that one. Processes in `excluding` are left out.
    public static func displayAwakeProcesses(_ assertions: [Int32: [[String: Any]]],
                                             excluding: Set<Int32> = []) -> [Int32] {
        var owners: [Int32] = []
        for (pid, list) in assertions.sorted(by: { $0.key < $1.key }) {
            for assertion in list {
                guard let type = assertion["AssertType"] as? String, displayAwakeTypes.contains(type) else { continue }
                let owner = (assertion["AssertionOnBehalfOfPID"] as? Int).map(Int32.init) ?? pid
                if !excluding.contains(owner), !owners.contains(owner) { owners.append(owner) }
            }
        }
        return owners
    }

    /// Why Dropy should not capture now, or nil. `stopsPlayback` is a running app that
    /// stops on capture (`blocker`), `playing` an app keeping the display awake.
    public static func refusal(neverCaptures: Bool, stopsPlayback: String?, playing: String?) -> CaptureFailure? {
        if neverCaptures { return .captureTurnedOff }
        if let stopsPlayback { return .captureStopsPlayback(applicationName: stopsPlayback) }
        if let playing { return .videoPlaying(applicationName: playing) }
        return nil
    }
}
