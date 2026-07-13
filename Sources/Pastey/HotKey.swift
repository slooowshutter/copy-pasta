import Carbon.HIToolbox

/// Global hotkey via Carbon — ~40 lines, no dependency, works on every macOS.
/// One hotkey supported; generalize if we ever need a second.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        HotKey.handler = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Installed once; re-binding only re-runs Unregister/Register in update().
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.handler?()
            return noErr
        }, 1, &eventType, nil, nil)
        update(keyCode: keyCode, modifiers: modifiers)
    }

    /// Swap the registered combo in place (keep the same instance, so the one-time
    /// event handler isn't reinstalled and the static handler stays valid).
    func update(keyCode: UInt32, modifiers: UInt32) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        let id = EventHotKeyID(signature: OSType(0x50535459), id: 1) // "PSTY"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
