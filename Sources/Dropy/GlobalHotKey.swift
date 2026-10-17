import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut. Carbon hot keys need no Accessibility
/// permission and do not wake Dropy until the combination is pressed, which keeps
/// the closed overlay free of background work.
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let identifier: UInt32
    private static var nextIdentifier: UInt32 = 0

    /// Returns nil when the combination is already taken by another app.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        Self.nextIdentifier += 1
        identifier = Self.nextIdentifier
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var received = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &received) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            return MainActor.assumeIsolated {
                guard received.signature == OSType(0x4452_5059), received.id == hotKey.identifier else {
                    return OSStatus(eventNotHandledErr)
                }
                hotKey.action()
                return noErr
            }
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let identifier = EventHotKeyID(signature: OSType(0x4452_5059), id: identifier) // "DRPY"
        let registered = RegisterEventHotKey(keyCode, modifiers, identifier,
                                             GetApplicationEventTarget(), 0, &hotKey)
        guard installed == noErr, registered == noErr else {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            if let handler { RemoveEventHandler(handler) }
            NSLog("Dropy shortcut unavailable: handler=%d register=%d", installed, registered)
            return nil
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
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
