import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut. Carbon hot keys need no Accessibility
/// permission and do not wake Dropy until the combination is pressed, which keeps
/// the closed overlay free of background work.
@MainActor
final class GlobalHotKey {
    /// The native boundary is injectable so failure and teardown checks never
    /// register a real system shortcut or generate input.
    struct System {
        var install: (EventHandlerUPP, UnsafeMutableRawPointer, inout EventHandlerRef?) -> OSStatus
        var register: (UInt32, UInt32, EventHotKeyID, inout EventHotKeyRef?) -> OSStatus
        var unregister: (EventHotKeyRef) -> Void
        var remove: (EventHandlerRef) -> Void

        static var live: System {
            System(install: { callback, context, handler in
                var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                         eventKind: UInt32(kEventHotKeyPressed))
                return InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, context, &handler)
            }, register: { keyCode, modifiers, identifier, hotKey in
                RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
            }, unregister: { UnregisterEventHotKey($0) }, remove: { RemoveEventHandler($0) })
        }
    }

    private final class Receiver {
        let identifier: UInt32
        let action: () -> Void
        init(identifier: UInt32, action: @escaping () -> Void) {
            self.identifier = identifier
            self.action = action
        }
    }

    private var cleanup: MainThreadCleanup?
    private static var nextIdentifier: UInt32 = 0

    /// Returns nil when the combination is already taken by another app.
    init?(keyCode: UInt32, modifiers: UInt32, system: System = .live, action: @escaping () -> Void) {
        Self.nextIdentifier += 1
        let receiver = Receiver(identifier: Self.nextIdentifier, action: action)
        var handler: EventHandlerRef?
        let installed = system.install({ _, event, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            var received = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &received) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            return MainActor.assumeIsolated {
                let receiver = Unmanaged<Receiver>.fromOpaque(userData).takeUnretainedValue()
                guard received.signature == OSType(0x4452_5059), received.id == receiver.identifier else {
                    return OSStatus(eventNotHandledErr)
                }
                receiver.action()
                return noErr
            }
        }, Unmanaged.passUnretained(receiver).toOpaque(), &handler)
        var hotKey: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x4452_5059), id: receiver.identifier) // "DRPY"
        let registered = installed == noErr
            ? system.register(keyCode, modifiers, identifier, &hotKey) : OSStatus(eventNotHandledErr)
        let registeredKey = hotKey, installedHandler = handler
        cleanup = MainThreadCleanup {
            if let registeredKey { system.unregister(registeredKey) }
            if let installedHandler { system.remove(installedHandler) }
            // Carbon does not retain userData. Keep it alive through removal,
            // including cleanup queued after an off-main final release.
            withExtendedLifetime(receiver) {}
        }
        guard installed == noErr, registered == noErr else {
            unregister()
            NSLog("Dropy shortcut unavailable: handler=%d register=%d", installed, registered)
            return nil
        }
    }

    func unregister() { cleanup = nil }

}

extension GlobalHotKey {
    /// True when macOS already uses the shortcut (Turn Dock hiding on/off, Spotlight,
    /// input sources…). Registering it succeeds anyway and both fire, so it has to be
    /// checked up front.
    static func systemConflict(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let hotKeys = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        return hotKeys.contains { hotKey in
            hotKey[kHISymbolicHotKeyEnabled as String] as? Bool == true
                && hotKey[kHISymbolicHotKeyCode as String] as? Int == Int(keyCode)
                && hotKey[kHISymbolicHotKeyModifiers as String] as? Int == Int(modifiers)
        }
    }
}
