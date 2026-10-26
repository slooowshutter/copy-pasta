import AppKit
import Carbon

/// "Paste directly": after the panel puts an item on the pasteboard, type ⌘V into the
/// app the user was in. Posting key events needs Accessibility permission — without
/// it they're silently dropped, so callers check `isTrusted` first.
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt, which also lists Pastey in
    /// System Settings › Privacy & Security › Accessibility.
    static func requestAccess() {
        // The value of kAXTrustedCheckOptionPrompt (its Swift import differs across SDKs).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func pasteIntoFrontApp() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = keyCodeForV()
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgSessionEventTap)
        }
    }

    /// The key that types "v" with ⌘ held in the current layout — not always the ANSI
    /// V key (Dvorak). Falls back to ANSI V if the layout has no Unicode key data.
    private static func keyCodeForV() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        return layoutData.withUnsafeBytes { buffer -> CGKeyCode in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return fallback }
            for code in 0..<UInt16(128) {
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), commandState,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKeys, 4, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(UInt8(ascii: "v")) {
                    return CGKeyCode(code)
                }
            }
            return fallback
        }
    }
}
