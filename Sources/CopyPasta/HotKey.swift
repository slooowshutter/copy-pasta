import Carbon.HIToolbox

/// CopyPasta's global hotkeys (Activate CopyPasta, dictation) via Carbon: no dependency,
/// works on every macOS. One event handler, installed with the first hotkey, hands each
/// press to its hotkey by id.
final class HotKey {
    /// While Settings records a shortcut, every hotkey is unregistered so its keys reach the
    /// recorder (a registered combo never arrives as a key press), then registered again.
    static var isPaused = false {
        didSet { if isPaused != oldValue { all.forEach { $0.apply() } } }
    }

    // ponytail: hotkeys live as long as the app, so they're kept here and never removed.
    private static var all: [HotKey] = []
    private static let signature = OSType(0x50535459) // "PSTY"

    private let id: UInt32
    private let action: () -> Void
    private var ref: EventHotKeyRef?
    private var shortcut: Shortcut?
    private var lastPress = Date.distantPast

    init(action: @escaping () -> Void) {
        if Self.all.isEmpty { Self.installHandler() }
        id = UInt32(Self.all.count)
        self.action = action
        Self.all.append(self)
    }

    /// Registers `shortcut` in place of the previous one; false if another app holds it.
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        self.shortcut = shortcut
        return apply()
    }

    @discardableResult
    private func apply() -> Bool {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard let shortcut, !Self.isPaused else { return true }
        // Exclusive: without it, registering a combo another app holds "succeeds" and the
        // shortcut just never fires. This way we fail loudly and can tell the user.
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &newRef)
        guard status == noErr else {
            plog("hotkey \(shortcut.glyphs) registration failed (\(status))")
            return false
        }
        ref = newRef
        return true
    }

    /// One press can arrive twice: the second, within 0.15s, is ignored.
    private func fire() {
        guard Date().timeIntervalSince(lastPress) > 0.15 else { return }
        lastPress = Date()
        action()
    }

    private static func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKey.signature, Int(id.id) < HotKey.all.count else {
                return OSStatus(eventNotHandledErr)
            }
            HotKey.all[Int(id.id)].fire()
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
