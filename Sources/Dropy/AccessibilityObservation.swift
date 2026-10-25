import ApplicationServices
import Foundation

/// An Accessibility observer and all of its notification registrations. Removing
/// the run-loop source comes before releasing the callback context or AXObserver.
@MainActor
final class AccessibilityObservation {
    struct System {
        var create: (pid_t, AXObserverCallback, inout AXObserver?) -> AXError
        var add: (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer) -> AXError

        static var live: System {
            .init(create: { AXObserverCreate($0, $1, &$2) },
                  add: { AXObserverAddNotification($0, $1, $2, $3) })
        }
    }

    private final class Callback {
        let handle: @MainActor (String) -> Void
        init(_ handle: @escaping @MainActor (String) -> Void) { self.handle = handle }
    }

    private let cleanup: MainThreadCleanup

    init?(processID: pid_t, notifications: [(element: AXUIElement, name: String)],
          system: System = .live,
          handle: @escaping @MainActor (String) -> Void) {
        let callback = Callback(handle)
        var observer: AXObserver?
        guard system.create(processID, { _, _, notification, pointer in
            guard let pointer else { return }
            MainActor.assumeIsolated {
                Unmanaged<Callback>.fromOpaque(pointer).takeUnretainedValue().handle(notification as String)
            }
        }, &observer) == .success, let observer else { return nil }
        let pointer = Unmanaged.passUnretained(callback).toOpaque()
        var added = 0
        for (element, name) in notifications {
            if system.add(observer, element, name as CFString, pointer) == .success { added += 1 }
        }
        guard added > 0 else { return nil }
        let source = AXObserverGetRunLoopSource(observer)
        cleanup = MainThreadCleanup {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            withExtendedLifetime((observer, callback)) {}
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }
}
