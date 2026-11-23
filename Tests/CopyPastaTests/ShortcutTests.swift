import AppKit
import Carbon.HIToolbox
import XCTest
@testable import CopyPasta

@MainActor
final class ShortcutTests: XCTestCase {
    private let current: [ShortcutAction: Shortcut] = [
        .activate: ShortcutAction.activate.defaultShortcut,
        .dictation: ShortcutAction.dictation.defaultShortcut,
    ]

    private func shortcut(_ key: Int, _ modifiers: Int, _ label: String = "X") -> Shortcut {
        Shortcut(keyCode: UInt32(key), modifiers: UInt32(modifiers), label: label)
    }

    func testProblems() {
        XCTAssertNil(shortcut(kVK_ANSI_D, controlKey | optionKey).problem(as: .dictation, among: current))
        XCTAssertNil(shortcut(kVK_Space, optionKey).problem(as: .dictation, among: current)) // SuperSamuel's ⌥Space
        XCTAssertNil(shortcut(kVK_F5, 0).problem(as: .dictation, among: current))
        XCTAssertNil(ShortcutAction.dictation.defaultShortcut.problem(as: .dictation, among: current)) // re-recording it
        XCTAssertNotNil(shortcut(kVK_ANSI_D, 0).problem(as: .dictation, among: current))
        XCTAssertNotNil(shortcut(kVK_ANSI_D, shiftKey).problem(as: .dictation, among: current))
        XCTAssertNotNil(shortcut(kVK_ANSI_V, cmdKey).problem(as: .dictation, among: current)) // ⌘V would break paste
        XCTAssertNotNil(ShortcutAction.activate.defaultShortcut.problem(as: .dictation, among: current))
    }

    /// A ⌘W saved by an older version goes back to ⇧⌘V instead of taking ⌘W from every app.
    func testDisallowedSavedShortcutFallsBackToDefault() throws {
        let suite = "copypasta-shortcut-test-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set(kVK_ANSI_W, forKey: "shortcutKeyCode")
        d.set(cmdKey, forKey: "shortcutModifiers")
        d.set("W", forKey: "shortcutKeyLabel")
        d.set(kVK_ANSI_D, forKey: "dictationShortcutKeyCode")
        d.set(controlKey | optionKey, forKey: "dictationShortcutModifiers")
        d.set("D", forKey: "dictationShortcutKeyLabel")

        let loaded = AppSettings.loadShortcuts(d)
        XCTAssertEqual(loaded[.activate], ShortcutAction.activate.defaultShortcut)
        XCTAssertNil(d.object(forKey: "shortcutKeyCode"))
        XCTAssertEqual(loaded[.dictation]?.glyphs, "⌃⌥D")
    }

    /// Click, press keys, check what's saved and that CopyPasta's hotkeys are paused only while recording.
    func testRecordingDictationShortcut() throws {
        let settings = AppSettings.shared
        let saved = settings.shortcut(.dictation)
        defer { settings.setShortcut(saved, for: .dictation); settings.shortcutError = nil }

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: .titled, backing: .buffered, defer: false) // never shown
        window.isReleasedWhenClosed = false
        let recorder = RecorderView(action: .dictation)
        recorder.frame = NSRect(x: 10, y: 10, width: 110, height: 22)
        window.contentView!.addSubview(recorder)

        func press(_ key: Int, _ flags: NSEvent.ModifierFlags, _ chars: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(key)))
            NSApp.sendEvent(event)
        }

        recorder.mouseDown(with: NSEvent())
        XCTAssertTrue(HotKey.isPaused)
        try press(kVK_ANSI_D, .shift, "D")        // refused: still recording
        XCTAssertNotNil(settings.shortcutError)
        XCTAssertTrue(HotKey.isPaused)
        try press(kVK_Escape, [], "\u{1b}")       // cancels
        XCTAssertFalse(HotKey.isPaused)
        XCTAssertEqual(settings.shortcut(.dictation), saved)

        recorder.mouseDown(with: NSEvent())
        try press(kVK_ANSI_W, .command, "w")      // not saved; stops so ⌘W can close the window
        XCTAssertFalse(HotKey.isPaused)
        XCTAssertNotNil(settings.shortcutError)
        XCTAssertEqual(settings.shortcut(.dictation), saved)

        recorder.mouseDown(with: NSEvent())
        try press(kVK_ANSI_1, [.control, .option, .shift], "!")
        XCTAssertFalse(HotKey.isPaused)
        XCTAssertNil(settings.shortcutError)
        XCTAssertEqual(settings.shortcut(.dictation).glyphs, "⌃⌥⇧1") // the key, not the shifted "!"

        recorder.mouseDown(with: NSEvent())
        recorder.removeFromSuperview()            // e.g. switching panes mid-recording
        XCTAssertFalse(HotKey.isPaused)
    }
}
