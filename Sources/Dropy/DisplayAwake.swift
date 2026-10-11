import AppKit
import DropyCore
import IOKit.pwr_mgt

/// Which app is keeping the display awake, as video players do while they play. Read
/// from the power assertions macOS keeps for every process (`pmset -g assertions`),
/// which any app may read.
enum DisplayAwake {
    /// The name of an app, other than Dropy, that keeps the display awake, or nil.
    static func application() -> String? {
        var copied: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&copied) == kIOReturnSuccess,
              let byProcess = copied?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        let assertions = Dictionary(byProcess.map { ($0.key.int32Value, $0.value) }, uniquingKeysWith: { $0 + $1 })
        for pid in CaptureGuard.displayAwakeProcesses(assertions, excluding: [getpid()]) {
            // A browser plays video in a helper process: name the app responsible for it.
            guard let application = app(for: pid) ?? responsible(for: pid).flatMap(app(for:)),
                  application.processIdentifier != getpid() else { continue }
            return application.localizedName ?? "An app"
        }
        return nil
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
