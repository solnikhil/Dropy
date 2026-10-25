import Carbon.HIToolbox
import Foundation

private final class HotKeyContext: Sendable {}

@MainActor private final class HotKeySystemFixture {
    var installs = 0
    var registrations = 0
    var unregistrations = 0
    var removals = 0
    var installStatus: OSStatus = noErr
    var registerStatus: OSStatus = noErr
    weak var context: HotKeyContext?

    var system: GlobalHotKey.System {
        .init(install: { _, _, handle in
            self.installs += 1
            handle = OpaquePointer(bitPattern: 1)
            return self.installStatus
        }, register: { _, _, _, key in
            self.registrations += 1
            key = OpaquePointer(bitPattern: 2)
            return self.registerStatus
        }, unregister: { _ in
            precondition(self.context != nil, "The callback context must outlive native unregistration")
            self.unregistrations += 1
        }, remove: { _ in
            precondition(self.context != nil, "The callback context must outlive handler removal")
            self.removals += 1
        })
    }
}

@main struct HotKeyLifetimeChecks {
    @MainActor static func main() {
        for explicitlyStop in [false, true] {
            let fixture = HotKeySystemFixture()
            for _ in 0..<100 {
                var context: HotKeyContext? = HotKeyContext()
                fixture.context = context
                var hotKey = GlobalHotKey(keyCode: 0, modifiers: 0, system: fixture.system) { [context = context!] in
                    withExtendedLifetime(context) {}
                }
                context = nil
                precondition(hotKey != nil && fixture.context != nil)
                if explicitlyStop {
                    hotKey?.unregister()
                    hotKey?.unregister()
                    precondition(fixture.context == nil)
                }
                hotKey = nil
                precondition(fixture.context == nil, "Destruction must also remove the native callback and its context")
            }
            precondition(fixture.installs == 100 && fixture.registrations == 100)
            precondition(fixture.unregistrations == 100 && fixture.removals == 100,
                         "Each native resource must be released exactly once")
        }

        for failedInstall in [false, true] {
            let fixture = HotKeySystemFixture()
            if failedInstall { fixture.installStatus = -1 } else { fixture.registerStatus = -1 }
            var context: HotKeyContext? = HotKeyContext()
            fixture.context = context
            let hotKey = GlobalHotKey(keyCode: 0, modifiers: 0, system: fixture.system) { [context = context!] in
                withExtendedLifetime(context) {}
            }
            context = nil
            precondition(hotKey == nil && fixture.context == nil)
            precondition(fixture.registrations == (failedInstall ? 0 : 1))
            precondition(fixture.unregistrations == (failedInstall ? 0 : 1) && fixture.removals == 1,
                         "Partial failures must release only the resources that were created")
        }
        print("Hot key lifecycle checks passed (200 create/destroy cycles, explicit stop, partial failures; controlled IO)")
    }
}
