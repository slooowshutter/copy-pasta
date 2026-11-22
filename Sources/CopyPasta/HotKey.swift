import Carbon.HIToolbox

/// Global hotkey via Carbon — ~40 lines, no dependency, works on every macOS.
/// One hotkey supported; generalize if we ever need a second.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?

    /// False when another app (Paste, Maccy…) already holds the combo.
    private(set) var isRegistered = false

    /// "PSTY". Dictation's ⌥⇧⌘Space (HotkeyService) is "SSHK": each handler only takes its own.
    private static let signature = OSType(0x50535459)

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        HotKey.handler = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Installed once; re-binding only re-runs Unregister/Register in update().
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKey.signature else {
                return OSStatus(eventNotHandledErr) // another hotkey: let its handler have it
            }
            HotKey.handler?()
            return noErr
        }, 1, &eventType, nil, nil)
        update(keyCode: keyCode, modifiers: modifiers)
    }

    /// Swap the registered combo in place (keep the same instance, so the one-time
    /// event handler isn't reinstalled and the static handler stays valid).
    @discardableResult
    func update(keyCode: UInt32, modifiers: UInt32) -> Bool {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        let id = EventHotKeyID(signature: HotKey.signature, id: 1)
        // Exclusive: without it, registering a combo another app holds "succeeds" and
        // the shortcut just never fires. This way we fail loudly and can tell the user.
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        isRegistered = status == noErr
        if !isRegistered { plog("hotkey registration failed (\(status))") }
        return isRegistered
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
