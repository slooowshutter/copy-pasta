import AppKit
import ServiceManagement
import Carbon.HIToolbox

/// How long rolling history is kept. `forever` = never age-prune.
enum KeepHistory: Int, CaseIterable {
    case day, week, month, year, forever

    var seconds: TimeInterval {
        switch self {
        case .day:     return 86_400
        case .week:    return 86_400 * 7
        case .month:   return 86_400 * 30
        case .year:    return 86_400 * 365
        case .forever: return .infinity
        }
    }

    var label: String {
        switch self {
        case .day:     return "Day"
        case .week:    return "Week"
        case .month:   return "Month"
        case .year:    return "Year"
        case .forever: return "Forever"
        }
    }
}

/// The app's one preferences store — UserDefaults-backed, observable for SwiftUI.
/// Side effects live in the `didSet`s (login item, DB prune) or fire the callback
/// seams (`onMenuBarChange`/`onShortcutChange`) that AppDelegate wires at launch,
/// so this type stays free of a hard dependency on AppDelegate.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    var onMenuBarChange: ((Bool) -> Void)?
    var onShortcutChange: (() -> Void)?

    // Guards: SwiftUI can re-assign a binding its current value, which would re-run
    // these side effects (re-register login item + its macOS toast, rebuild the
    // status item, re-prune) on every settings open. Only act on a real change.
    @Published var openAtLogin: Bool { didSet { if openAtLogin != oldValue { syncLoginItem() } } }
    @Published var showInMenuBar: Bool { didSet {
        d.set(showInMenuBar, forKey: Keys.menuBar)
        if showInMenuBar != oldValue { onMenuBarChange?(showInMenuBar) }
    } }
    @Published var soundEffects: Bool { didSet { d.set(soundEffects, forKey: Keys.sound) } }
    @Published var keepHistory: KeepHistory { didSet {
        d.set(keepHistory.rawValue, forKey: Keys.keepHistory)
        if keepHistory != oldValue { DB.shared.pruneHistory(olderThan: keepHistory.seconds) }
    } }

    // Shortcut is mutated only through setShortcut/resetShortcut so its three parts
    // stay consistent and the re-register callback fires exactly once.
    @Published private(set) var shortcutKeyCode: UInt32
    @Published private(set) var shortcutModifiers: UInt32
    @Published private(set) var shortcutKeyLabel: String

    static let defaultKeyCode = UInt32(kVK_ANSI_V)
    static let defaultModifiers = UInt32(cmdKey | shiftKey) // ⇧⌘V
    static let defaultLabel = "V"
    static var defaultGlyphs: String { modifierGlyphs(defaultModifiers) + defaultLabel }

    private let d = UserDefaults.standard
    private enum Keys {
        static let menuBar = "showInMenuBar"
        static let sound = "soundEffects"
        static let keepHistory = "keepHistory"
        static let keyCode = "shortcutKeyCode"
        static let modifiers = "shortcutModifiers"
        static let keyLabel = "shortcutKeyLabel"
    }

    private init() {
        d.register(defaults: [
            Keys.menuBar: true,
            Keys.sound: false,
            Keys.keepHistory: KeepHistory.month.rawValue,
            Keys.keyCode: Int(Self.defaultKeyCode),
            Keys.modifiers: Int(Self.defaultModifiers),
            Keys.keyLabel: Self.defaultLabel,
        ])
        // Login item's real source of truth is the system; reflect actual state.
        openAtLogin = (SMAppService.mainApp.status == .enabled)
        showInMenuBar = d.bool(forKey: Keys.menuBar)
        soundEffects = d.bool(forKey: Keys.sound)
        keepHistory = KeepHistory(rawValue: d.integer(forKey: Keys.keepHistory)) ?? .month
        shortcutKeyCode = UInt32(d.integer(forKey: Keys.keyCode))
        shortcutModifiers = UInt32(d.integer(forKey: Keys.modifiers))
        shortcutKeyLabel = d.string(forKey: Keys.keyLabel) ?? Self.defaultLabel
    }

    func setShortcut(keyCode: UInt32, modifiers: UInt32, label: String) {
        shortcutKeyCode = keyCode
        shortcutModifiers = modifiers
        shortcutKeyLabel = label
        d.set(Int(keyCode), forKey: Keys.keyCode)
        d.set(Int(modifiers), forKey: Keys.modifiers)
        d.set(label, forKey: Keys.keyLabel)
        onShortcutChange?()
    }

    func resetShortcut() {
        setShortcut(keyCode: Self.defaultKeyCode, modifiers: Self.defaultModifiers, label: Self.defaultLabel)
    }

    /// e.g. "⌥⇧⌘V" — for menu labels and the recorder display.
    var shortcutGlyphs: String { modifierGlyphs(shortcutModifiers) + shortcutKeyLabel }

    private func syncLoginItem() {
        do {
            if openAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            plog("login item toggle failed: \(error)")
        }
    }
}

/// Carbon modifier bitmask → glyphs, in the canonical ⌃⌥⇧⌘ order.
func modifierGlyphs(_ modifiers: UInt32) -> String {
    var s = ""
    if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
    if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
    if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
    if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
    return s
}

/// Non-printable keys shown as glyphs; printable keys use the event's own
/// `charactersIgnoringModifiers` at record time (correct on any keyboard layout).
let specialKeyNames: [UInt32: String] = [
    UInt32(kVK_Space):        "Space",
    UInt32(kVK_Return):       "↩",
    UInt32(kVK_Tab):          "⇥",
    UInt32(kVK_Delete):       "⌫",
    UInt32(kVK_ForwardDelete):"⌦",
    UInt32(kVK_LeftArrow):    "←",
    UInt32(kVK_RightArrow):   "→",
    UInt32(kVK_UpArrow):      "↑",
    UInt32(kVK_DownArrow):    "↓",
    UInt32(kVK_Home):         "↖",
    UInt32(kVK_End):          "↘",
    UInt32(kVK_PageUp):       "⇞",
    UInt32(kVK_PageDown):     "⇟",
]
