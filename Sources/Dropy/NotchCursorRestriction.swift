import AppKit
import ApplicationServices
import DropyCore

/// An opt-in active event filter. Installed on the main run loop, released on
/// timeout/permission failure, and bypassed by Option, drags, or an open overlay.
@MainActor
final class NotchCursorRestriction {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var previous: CGPoint?
    private var housings: [CGRect] = []
    private var screens: [CGRect] = []
    var onStatus: ((String) -> Void)?
    private let isArmed: () -> Bool
    init(isArmed: @escaping () -> Bool) { self.isArmed = isArmed }

    func configure(enabled: Bool, housings: [CGRect], screens: [CGRect]) {
        stop()
        self.housings = housings
        self.screens = screens
        guard enabled else { onStatus?("Off"); return }
        guard !housings.isEmpty else { onStatus?("Unavailable on this display"); return }
        guard AXIsProcessTrusted() else { onStatus?("Waiting for Accessibility permission"); return }
        previous = CGEvent(source: nil)?.location
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            MainActor.assumeIsolated {
                let owner = Unmanaged<NotchCursorRestriction>.fromOpaque(context).takeUnretainedValue()
                owner.filter(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            onStatus?("Unavailable: macOS did not allow the cursor filter")
            NSLog("Dropy experimental cursor restriction unavailable")
            return
        }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onStatus?("Active while Dropy is closed · Option bypasses")
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; previous = nil
        onStatus?("Inactive")
    }

    private func filter(type: CGEventType, event: CGEvent) {
        guard type == .mouseMoved else {
            // Fail open rather than repeatedly fighting the system after timeout.
            previous = nil
            onStatus?("Disabled by macOS · toggle the option to retry")
            return
        }
        let point = event.location
        defer { previous = event.location }
        guard isArmed(), !event.flags.contains(.maskAlternate),
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right),
              let previous else { return }
        for (housing, screen) in zip(housings, screens) {
            guard screen.contains(previous), screen.contains(point) else { continue }
            guard let constrained = NotchCursorBarrier.constrained(from: previous, to: point, housing: housing) else { continue }
            if CGWarpMouseCursorPosition(constrained) == .success { event.location = constrained }
            break
        }
        return
    }
}
