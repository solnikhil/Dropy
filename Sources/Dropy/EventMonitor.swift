import AppKit

/// Removing a monitor owner also removes AppKit's registration and handler.
@MainActor
final class EventMonitor {
    private let cleanup: MainThreadCleanup

    private init(_ token: Any) {
        cleanup = MainThreadCleanup { NSEvent.removeMonitor(token) }
    }

    static func global(matching mask: NSEvent.EventTypeMask,
                       handler: @escaping @MainActor (NSEvent) -> Void) -> EventMonitor? {
        NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler).map(EventMonitor.init)
    }

    static func local(matching mask: NSEvent.EventTypeMask,
                      handler: @escaping @MainActor (NSEvent) -> NSEvent?) -> EventMonitor? {
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler).map(EventMonitor.init)
    }
}
