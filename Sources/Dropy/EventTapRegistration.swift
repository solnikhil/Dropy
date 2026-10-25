import AppKit

/// Owns an event tap, its run-loop source and a callback context together. The
/// context can weakly reference a session; native callbacks never dereference a
/// destroyed session, even if final release has to queue main-thread teardown.
@MainActor
final class EventTapRegistration {
    struct System {
        var create: (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort?
        var makeSource: (CFMachPort) -> CFRunLoopSource?
        var enable: (CFMachPort, Bool) -> Void
        var invalidate: (CFMachPort) -> Void

        static var live: System {
            .init(create: { mask, callback, context in
                CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                  eventsOfInterest: mask, callback: callback, userInfo: context)
            }, makeSource: { CFMachPortCreateRunLoopSource(kCFAllocatorDefault, $0, 0) },
                  enable: { CGEvent.tapEnable(tap: $0, enable: $1) }, invalidate: { CFMachPortInvalidate($0) })
        }
    }

    private final class Callback {
        let filter: @MainActor (CGEventType, CGEvent) -> Void
        init(_ filter: @escaping @MainActor (CGEventType, CGEvent) -> Void) { self.filter = filter }
    }

    private let port: CFMachPort
    private let system: System
    private let cleanup: MainThreadCleanup

    init?(eventsOfInterest: CGEventMask, system: System = .live,
          filter: @escaping @MainActor (CGEventType, CGEvent) -> Void) {
        let callback = Callback(filter)
        guard let port = system.create(eventsOfInterest, { _, type, event, pointer in
                if let pointer {
                    MainActor.assumeIsolated {
                        Unmanaged<Callback>.fromOpaque(pointer).takeUnretainedValue().filter(type, event)
                    }
                }
                return Unmanaged.passUnretained(event)
            }, Unmanaged.passUnretained(callback).toOpaque()) else { return nil }
        guard let source = system.makeSource(port) else {
            // A successful tap creation is a native registration even when its
            // run-loop source cannot be created. It still needs invalidation.
            system.invalidate(port)
            return nil
        }
        self.port = port
        self.system = system
        cleanup = MainThreadCleanup {
            system.enable(port, false)
            system.invalidate(port)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            withExtendedLifetime(callback) {}
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) { system.enable(port, enabled) }
}
