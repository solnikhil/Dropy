import AppKit
import CoreMedia
import DropyCore
import ScreenCaptureKit

// Compile the production LiveCaster against deterministic capture IO. Types here
// shadow the SDK at the IO boundary; no recording request or window is created.
@MainActor private final class CaptureGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func entered() async {
        for _ in 0..<10_000 {
            if continuation != nil { return }
            await Task.yield()
        }
        preconditionFailure("Capture never reached its gate")
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor final class MetalFrameView: NSView {}
enum HostClock { static func nowMilliseconds() -> Double { 0 } }
@MainActor final class CaptureMetricsRecorder {
    init(windowID: UInt32, requestedAt: Double) {}
    func startReturned() {}
    func finish(reason: String) {}
}
@MainActor final class FrameMailbox {
    var invalidated = false
    init(renderer: MetalFrameView, metrics: CaptureMetricsRecorder,
         onActivityChange: @escaping @Sendable (Bool, Int) -> Void) {}
    func setGeometry(_ geometry: CaptureGeometry) {}
    func invalidate() { invalidated = true }
}
final class StreamStopObserver: NSObject, @unchecked Sendable {
    private let onStop: @Sendable (Error) -> Void
    init(onStop: @escaping @Sendable (Error) -> Void) { self.onStop = onStop }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop(error) }
}
struct FixtureDisplay { let displayID: CGDirectDisplayID }
struct FixtureApplication { let processID: Int32 }
@MainActor final class SCShareableContent {
    fileprivate static var nextGate: CaptureGate?
    let displays = [FixtureDisplay(displayID: 17)]
    let applications: [FixtureApplication] = []
    static func excludingDesktopWindows(_ excluded: Bool, onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        if let gate = nextGate { nextGate = nil; await gate.wait() }
        return SCShareableContent()
    }
}
@MainActor final class SCContentFilter {
    init(display: FixtureDisplay, excludingApplications: [FixtureApplication], exceptingWindows: [Int]) {}
}
@MainActor final class SCStream {
    fileprivate static var nextGate: CaptureGate?
    static var nextFails = false
    static var instances: [SCStream] = []
    private let observer: StreamStopObserver
    fileprivate let gate: CaptureGate?
    private let fails: Bool
    var stops = 0
    var mailbox: FrameMailbox?
    init(filter: SCContentFilter, configuration: SCStreamConfiguration, delegate: StreamStopObserver) {
        observer = delegate
        gate = Self.nextGate; Self.nextGate = nil
        fails = Self.nextFails; Self.nextFails = false
        Self.instances.append(self)
    }
    func addStreamOutput(_ mailbox: FrameMailbox, type: SCStreamOutputType, sampleHandlerQueue: DispatchQueue) throws {
        self.mailbox = mailbox
    }
    func startCapture() async throws {
        if let gate { await gate.wait() }
        if fails { throw NSError(domain: "fixture", code: 1) }
    }
    func stopCapture() async throws { stops += 1 }
    func stopUnexpectedly() { observer.stream(self, didStopWithError: NSError(domain: "fixture", code: 42)) }
}

@main struct LiveCasterChecks {
    @MainActor static func start(_ caster: LiveCaster, onStop: @escaping @MainActor (Error) -> Void = { _ in }) async throws {
        try await caster.start(stage: 17, region: CGRect(x: 0, y: 0, width: 500, height: 400),
                               windowID: 1, renderer: MetalFrameView(), refreshRate: 60, onUnexpectedStop: onStop)
    }
    @MainActor static func main() async throws {
        try await cancelledCatalogCannotStart()
        try await failedOldStartCannotClearNewStream()
        try await lateStartIsStoppedAgain()
        try await unexpectedStopInvalidatesFramesAndIgnoresOldEvents()
        print("Live capture lifecycle checks passed")
    }

    @MainActor static func cancelledCatalogCannotStart() async throws {
        let caster = LiveCaster(), gate = CaptureGate()
        SCShareableContent.nextGate = gate
        let initialCount = SCStream.instances.count
        let first = Task { try await start(caster) }
        await gate.entered()
        await caster.stop().value
        try await start(caster)
        let current = SCStream.instances.last!
        gate.resume()
        do {
            try await first.value
            preconditionFailure("Cancelled catalog lookup must not create a stream")
        } catch is CancellationError {}
        precondition(SCStream.instances.count == initialCount + 1)
        await caster.stop().value
        precondition(current.stops == 1)
    }

    @MainActor static func failedOldStartCannotClearNewStream() async throws {
        let caster = LiveCaster(), gate = CaptureGate()
        SCStream.nextGate = gate; SCStream.nextFails = true
        let first = Task { try await start(caster) }
        await gate.entered()
        let old = SCStream.instances.last!
        try await start(caster)
        let current = SCStream.instances.last!
        precondition(old !== current && old.stops == 1)
        gate.resume()
        do {
            try await first.value
            preconditionFailure("Expected old start failure")
        } catch { precondition((error as NSError).domain == "fixture") }
        await caster.stop().value
        precondition(current.stops == 1, "Old failure must not erase the new stream")
    }

    @MainActor static func lateStartIsStoppedAgain() async throws {
        let caster = LiveCaster(), gate = CaptureGate()
        SCStream.nextGate = gate
        let first = Task { try await start(caster) }
        await gate.entered()
        let old = SCStream.instances.last!
        await caster.stop().value
        gate.resume()
        do {
            try await first.value
            preconditionFailure("Late start must not become active")
        } catch is CancellationError {}
        precondition(old.stops == 2, "Late start needs a second stop acknowledgement")
    }

    @MainActor static func unexpectedStopInvalidatesFramesAndIgnoresOldEvents() async throws {
        let caster = LiveCaster()
        var callbacks = 0
        try await start(caster) { _ in callbacks += 1 }
        let old = SCStream.instances.last!
        await caster.stop().value
        try await start(caster) { error in
            precondition((error as NSError).code == 42)
            precondition(SCStream.instances.last!.mailbox!.invalidated)
            callbacks += 1
        }
        old.stopUnexpectedly()
        for _ in 0..<100 { await Task.yield() }
        precondition(callbacks == 0)
        let current = SCStream.instances.last!
        current.stopUnexpectedly()
        for _ in 0..<10_000 {
            if callbacks == 1, current.stops == 1 { break }
            await Task.yield()
        }
        precondition(callbacks == 1 && current.stops == 1)
        current.stopUnexpectedly()
        for _ in 0..<100 { await Task.yield() }
        precondition(callbacks == 1)
    }
}
