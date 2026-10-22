import Foundation
import CoreFoundation

/// Whether Dropy may capture the screen now. Any ScreenCaptureKit stream or
/// screenshot, even of a single other window for a fraction of a second, tells every
/// app on the Mac that the screen is being recorded (WindowServer logs "screen capture
/// added"; iPad-style apps see `UIScreen.isCaptured`). Some video players stop
/// playing when they hear it. Dropy's hidden display (the Stage) is worse: it has no
/// HDCP, so while it is connected no protected video (FairPlay) plays at all. So
/// docking a window captures nothing, and the preview, Live and the Stage first ask
/// this.
public enum CaptureGuard {
    /// Power assertion types that keep the display on. Video players take one while
    /// they play (AVPlayer does by default, browsers for a playing video).
    public static let displayAwakeTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// Words in the names players give their assertion (2026-10-20, from powerd's log):
    /// AVFoundation "com.apple.coremedia…" (Prime Video, QuickTime), Chromium
    /// "Video Wake Lock", WebKit "HTMLMediaElement playback", Firefox "video-playing".
    public static let videoAssertionWords = ["coremedia", "video", "playback"]

    /// Whether a display-awake assertion is a player's. Sound alone (coreaudiod's
    /// "com.apple.audio…" held for any app playing or recording audio), idle timers,
    /// Codex Computer Use and keep-awake tools are not, and they kept the Stage away
    /// for 15 minutes. An assertion without a name still counts.
    public static func isVideoAssertion(named name: String?) -> Bool {
        guard let name = name?.lowercased(), !name.isEmpty else { return true }
        return videoAssertionWords.contains { name.contains($0) }
    }

    /// Power assertion IDs must be positive integers representable by pid_t.
    /// Reject invalid external values instead of trapping or truncating to another process.
    public static func processIdentifier(from rawValue: Any?) -> Int32? {
        if let number = rawValue as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        guard let value = rawValue as? Int, value > 0 else { return nil }
        return Int32(exactly: value)
    }

    /// The processes keeping the display awake for video, from `IOPMCopyAssertionsByProcess`
    /// (process id → that process's assertions). An assertion made on behalf of another
    /// process counts for that one. Processes in `excluding` are left out.
    public static func displayAwakeProcesses(_ assertions: [Int32: [[String: Any]]],
                                             excluding: Set<Int32> = []) -> [Int32] {
        var owners: [Int32] = []
        for (pid, list) in assertions.sorted(by: { $0.key < $1.key }) {
            for assertion in list {
                guard let type = assertion["AssertType"] as? String, displayAwakeTypes.contains(type),
                      isVideoAssertion(named: assertion["AssertName"] as? String) else { continue }
                let owner = processIdentifier(from: assertion["AssertionOnBehalfOfPID"]) ?? pid
                guard owner > 0 else { continue }
                if !excluding.contains(owner), !owners.contains(owner) { owners.append(owner) }
            }
        }
        return owners
    }

    /// Why Dropy should not capture or add its hidden display now, or nil. `playing` is
    /// an app that played video recently (`VideoActivityLog`).
    public static func refusal(neverCaptures: Bool, playing: String?) -> CaptureFailure? {
        if neverCaptures { return .captureTurnedOff }
        if let playing { return .videoPlaying(applicationName: playing) }
        return nil
    }
}

/// Which apps played video lately, from the moments the set of apps keeping the
/// display awake changes. A paused video counts for a while: a FairPlay player checks
/// the displays again when it resumes, and refuses to play (an HDCP error) while
/// Dropy's hidden display, which has no HDCP, is connected.
public struct VideoActivityLog: Sendable {
    /// How long a video player counts after it last kept the display awake.
    public static let memory: TimeInterval = 15 * 60

    private var playing: Set<Int32> = []
    private var lastSeen: [Int32: Date] = [:]

    public init() {}

    /// Records the processes keeping the display awake at `date`; returns those that
    /// just started. One that just stopped counts as seen now.
    @discardableResult
    public mutating func observe(_ now: Set<Int32>, at date: Date) -> Set<Int32> {
        for pid in playing.union(now) { lastSeen[pid] = date }
        let started = now.subtracting(playing)
        playing = now
        return started
    }

    /// The process that played most recently within `memory` of `date`, among those
    /// `isAlive` still accepts.
    public func recent(at date: Date, isAlive: (Int32) -> Bool = { _ in true }) -> Int32? {
        lastSeen.filter { date.timeIntervalSince($0.value) <= Self.memory && isAlive($0.key) }
            .max { $0.value < $1.value }?.key
    }
}
