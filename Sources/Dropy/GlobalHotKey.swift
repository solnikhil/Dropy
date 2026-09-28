import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut. Carbon hot keys need no Accessibility
/// permission and do not wake Dropy until the combination is pressed, which keeps
/// the closed overlay free of background work.
@MainActor
final class GlobalHotKey {
    /// Option-Command-D: "D" for Dropy, and unused by macOS by default.
    static let defaultKeyCode = UInt32(kVK_ANSI_D)
    static let defaultModifiers = UInt32(optionKey | cmdKey)
    static let defaultDisplay = "⌥⌘D"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Returns nil when the combination is already taken by another app.
    init?(keyCode: UInt32 = defaultKeyCode, modifiers: UInt32 = defaultModifiers,
          action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let identifier = EventHotKeyID(signature: OSType(0x4452_5059), id: 1) // "DRPY"
        let registered = RegisterEventHotKey(keyCode, modifiers, identifier,
                                             GetApplicationEventTarget(), 0, &hotKey)
        guard installed == noErr, registered == noErr else {
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
