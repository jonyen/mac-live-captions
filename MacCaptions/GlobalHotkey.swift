import Foundation
import Carbon.HIToolbox

/// One system-wide hotkey via Carbon's RegisterEventHotKey — the only
/// global-hotkey API that needs no Accessibility permission, and it works
/// from an LSUIElement app with no window focused. Not @MainActor so deinit
/// can clean up; the callback is bounced to the main queue instead.
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    func register(_ binding: HotkeyBinding) {
        unregister()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { hotkey.onPress() }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4350_544E) /* 'CPTN' */, id: 1)
        RegisterEventHotKey(binding.keyCode, binding.modifiers, id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }

    deinit { unregister() }
}
