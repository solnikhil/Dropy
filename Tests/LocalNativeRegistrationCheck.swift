import AppKit
import ApplicationServices

private final class NativeCallbackContext: Sendable {}

@MainActor private final class TapFixture {
    var refusePort = false
    var refuseSource = false
    var enables: [Bool] = []
    var invalidations = 0
    var source: CFRunLoopSource?
    weak var context: NativeCallbackContext?

    var system: EventTapRegistration.System {
        .init(create: { _, _, _ in
            guard !self.refusePort else { return nil }
            // An ordinary local Mach port, not a system event tap. No input is
            // observed or injected by these lifecycle checks.
            return CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil)
        }, makeSource: { port in
            guard !self.refuseSource else { return nil }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            self.source = source
            return source
        }, enable: { _, enabled in
            precondition(self.context != nil)
            self.enables.append(enabled)
        }, invalidate: { port in
            precondition(self.context != nil, "Native teardown must precede callback-context destruction")
            self.invalidations += 1
            CFMachPortInvalidate(port)
        })
    }
}

@MainActor private final class AXFixture {
    var refuseCreate = false
    var refuseNotifications = false
    var observer: AXObserver?
    var adds = 0

    var system: AccessibilityObservation.System {
        .init(create: { pid, callback, observer in
            guard !self.refuseCreate else { return .failure }
            let status = AXObserverCreate(pid, callback, &observer)
            self.observer = observer
            return status
        }, add: { _, _, _, _ in
            // Do not register for any application's live Accessibility events.
            self.adds += 1
            return self.refuseNotifications ? .notificationUnsupported : .success
        })
    }
}

@main struct NativeRegistrationChecks {
    @MainActor static func main() {
        for failure in 0...2 {
            let fixture = TapFixture()
            fixture.refusePort = failure == 1
            fixture.refuseSource = failure == 2
            var context: NativeCallbackContext? = NativeCallbackContext()
            fixture.context = context
            var registration = EventTapRegistration(eventsOfInterest: 0, system: fixture.system) { [context = context!] _, _ in
                withExtendedLifetime(context) {}
            }
            context = nil
            if failure == 0 {
                precondition(registration != nil && fixture.context != nil)
                precondition(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.source, .commonModes))
                registration?.setEnabled(false)
                registration?.setEnabled(true)
            } else {
                precondition(registration == nil)
            }
            registration = nil
            precondition(fixture.context == nil)
            precondition(fixture.invalidations == (failure == 1 ? 0 : 1))
            if let source = fixture.source {
                precondition(!CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes))
                precondition(fixture.enables == [true, false, true, false])
            }
        }

        for failure in 0...2 {
            let fixture = AXFixture()
            fixture.refuseCreate = failure == 1
            fixture.refuseNotifications = failure == 2
            var context: NativeCallbackContext? = NativeCallbackContext()
            weak var released = context
            var observation = AccessibilityObservation(processID: getpid(),
                notifications: [(AXUIElementCreateApplication(getpid()), "TestOnly")],
                system: fixture.system) { [context = context!] _ in withExtendedLifetime(context) {} }
            context = nil
            if failure == 0 {
                precondition(observation != nil && released != nil)
                precondition(CFRunLoopContainsSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(fixture.observer!), .defaultMode))
            } else {
                precondition(observation == nil)
            }
            observation = nil
            precondition(released == nil)
            if let observer = fixture.observer {
                precondition(!CFRunLoopContainsSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode))
            }
        }
        print("Native registration checks passed (context/source teardown and partial failures; no input hooks or live AX subscriptions)")
    }
}
