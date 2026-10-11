import AppKit
import DropyCore
import IOKit.pwr_mgt

/// Apps playing video, seen through the power assertions macOS keeps for every
/// process (`pmset -g assertions`): video players keep the display awake while they
/// play (Prime Video, measured 2026-10-11; AVPlayer and browsers do by default).
/// Read every two seconds: a cheap call, and fast enough to take the Stage away as
/// a video starts.
@MainActor
final class VideoActivity {
    private var log = VideoActivityLog()
    private var timer: Timer?
    /// An app started keeping the display awake: a video began playing.
    var onPlaybackStarted: (() -> Void)?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// The name of an app that played video within the last minutes, or nil.
    func recentPlayer() -> String? {
        refresh()
        let pid = log.recent(at: Date()) { NSRunningApplication(processIdentifier: $0)?.isTerminated == false }
        return pid.map { NSRunningApplication(processIdentifier: $0)?.localizedName ?? "An app" }
    }

    private func refresh() {
        let started = log.observe(Self.applicationsKeepingDisplayAwake(), at: Date())
        if !started.isEmpty { onPlaybackStarted?() }
    }

    /// Apps, other than Dropy, keeping the display awake now.
    private static func applicationsKeepingDisplayAwake() -> Set<Int32> {
        var copied: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&copied) == kIOReturnSuccess,
              let byProcess = copied?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let assertions = Dictionary(byProcess.map { ($0.key.int32Value, $0.value) }, uniquingKeysWith: { $0 + $1 })
        var apps: Set<Int32> = []
        for pid in CaptureGuard.displayAwakeProcesses(assertions, excluding: [getpid()]) {
            // A browser plays video in a helper process: count the app responsible for it.
            guard let application = app(for: pid) ?? responsible(for: pid).flatMap(app(for:)),
                  application.processIdentifier != getpid() else { continue }
            apps.insert(application.processIdentifier)
        }
        return apps
    }

    private static func app(for pid: pid_t) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid).flatMap { $0.activationPolicy == .regular ? $0 : nil }
    }

    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    /// The process macOS holds responsible for `pid` (the app that started a helper).
    private static func responsible(for pid: pid_t) -> pid_t? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        let owner = unsafeBitCast(symbol, to: ResponsiblePID.self)(pid)
        return owner > 0 && owner != pid ? owner : nil
    }
}
