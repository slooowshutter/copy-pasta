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

/// Panel background material. `off` = classic HUD material (works on any macOS);
/// `clear`/`frosted` are Liquid Glass (macOS 26+) — clear is more see-through, frosted more opaque.
enum GlassStyle: Int, CaseIterable {
    case off, clear, frosted

    var label: String {
        switch self {
        case .off:     return "Off"
        case .clear:   return "Clear"
        case .frosted: return "Frosted"
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
    /// Re-registers the global hotkey with the current shortcut; false if another app holds it.
    var onShortcutChange: (() -> Bool)?

    // Guards: SwiftUI can re-assign a binding its current value, which would re-run
    // these side effects (re-register login item + its macOS toast, rebuild the
    // status item, re-prune) on every settings open. Only act on a real change.
    @Published var openAtLogin: Bool { didSet { if openAtLogin != oldValue { syncLoginItem() } } }
    @Published var showInMenuBar: Bool { didSet {
        d.set(showInMenuBar, forKey: Keys.menuBar)
        if showInMenuBar != oldValue { onMenuBarChange?(showInMenuBar) }
    } }
    @Published var soundEffects: Bool { didSet { d.set(soundEffects, forKey: Keys.sound) } }
    /// Enter / double-click pastes into the frontmost app (needs Accessibility), not just copies.
    @Published var pasteDirectly: Bool { didSet { d.set(pasteDirectly, forKey: Keys.pasteDirectly) } }
    @Published var glassStyle: GlassStyle { didSet { d.set(glassStyle.rawValue, forKey: Keys.glassStyle) } }
    /// Hold ⌘ and tap C twice: translate (French ↔ English). Three times: fix typos.
    @Published var translateOnDoubleCopy: Bool { didSet { d.set(translateOnDoubleCopy, forKey: Keys.translate) } }
    @Published var fixTyposOnTripleCopy: Bool { didSet { d.set(fixTyposOnTripleCopy, forKey: Keys.fixTypos) } }
    /// OpenRouter model for both. ":nitro" routes to the fastest provider serving it;
    /// Gemma 4 31B answered in 0.2–0.4s in testing (Nov 2026), translations and fixes clean.
    @Published var textModel: String { didSet { d.set(textModel, forKey: Keys.textModel) } }
    static let defaultTextModel = "google/gemma-4-31b-it:nitro"
    @Published var keepHistory: KeepHistory { didSet {
        d.set(keepHistory.rawValue, forKey: Keys.keepHistory)
        if keepHistory != oldValue { DB.shared.pruneHistory(olderThan: keepHistory.seconds) }
    } }

    // Shortcut is mutated only through setShortcut/resetShortcut so its three parts
    // stay consistent and the hotkey is only re-registered with all three in place.
    @Published private(set) var shortcutKeyCode: UInt32
    @Published private(set) var shortcutModifiers: UInt32
    @Published private(set) var shortcutKeyLabel: String
    /// Runtime only: set by AppDelegate when another app already owns the shortcut.
    @Published var shortcutUnavailable = false
    /// Runtime only: the last combo recorded in Settings that another app owns (not kept).
    @Published var rejectedShortcut: String?

    static let defaultKeyCode = UInt32(kVK_ANSI_V)
    static let defaultModifiers = UInt32(cmdKey | shiftKey) // ⇧⌘V
    static let defaultLabel = "V"
    static var defaultGlyphs: String { modifierGlyphs(defaultModifiers) + defaultLabel }

    private let d = UserDefaults.standard
    private enum Keys {
        static let menuBar = "showInMenuBar"
        static let sound = "soundEffects"
        static let pasteDirectly = "pasteDirectly"
        static let glassStyle = "glassStyle"
        static let keepHistory = "keepHistory"
        static let keyCode = "shortcutKeyCode"
        static let modifiers = "shortcutModifiers"
        static let keyLabel = "shortcutKeyLabel"
        static let translate = "translateOnDoubleCopy"
        static let fixTypos = "fixTyposOnTripleCopy"
        static let textModel = "textModel"
    }

    private init() {
        d.register(defaults: [
            Keys.menuBar: true,
            Keys.sound: false,
            Keys.pasteDirectly: true,
            Keys.glassStyle: GlassStyle.off.rawValue,
            Keys.keepHistory: KeepHistory.month.rawValue,
            Keys.keyCode: Int(Self.defaultKeyCode),
            Keys.modifiers: Int(Self.defaultModifiers),
            Keys.keyLabel: Self.defaultLabel,
            Keys.translate: true,
            Keys.fixTypos: true,
            Keys.textModel: Self.defaultTextModel,
        ])
        // Login item's real source of truth is the system; reflect actual state.
        openAtLogin = (SMAppService.mainApp.status == .enabled)
        showInMenuBar = d.bool(forKey: Keys.menuBar)
        soundEffects = d.bool(forKey: Keys.sound)
        pasteDirectly = d.bool(forKey: Keys.pasteDirectly)
        glassStyle = GlassStyle(rawValue: d.integer(forKey: Keys.glassStyle)) ?? .off
        keepHistory = KeepHistory(rawValue: d.integer(forKey: Keys.keepHistory)) ?? .month
        shortcutKeyCode = UInt32(d.integer(forKey: Keys.keyCode))
        shortcutModifiers = UInt32(d.integer(forKey: Keys.modifiers))
        shortcutKeyLabel = d.string(forKey: Keys.keyLabel) ?? Self.defaultLabel
        translateOnDoubleCopy = d.bool(forKey: Keys.translate)
        fixTyposOnTripleCopy = d.bool(forKey: Keys.fixTypos)
        textModel = d.string(forKey: Keys.textModel) ?? Self.defaultTextModel
    }

    // MARK: OpenRouter key

    /// The OpenRouter API key (⌘C-C, ⌘C-C-C, dictation), in a private file. Dictation's
    /// SettingsStore reads and writes the same one.
    var openRouterKey: String? {
        get { SharedAPIKey.openRouter.read() }
        set {
            objectWillChange.send()
            try? SharedAPIKey.openRouter.write(newValue ?? "")
        }
    }

    /// Saves and registers a new shortcut. If another app already holds the combo, keeps
    /// the current one instead (rather than leave CopyPasta with no shortcut at all), sets
    /// `rejectedShortcut`, and returns false.
    @discardableResult
    func setShortcut(keyCode: UInt32, modifiers: UInt32, label: String) -> Bool {
        let old = (keyCode: shortcutKeyCode, modifiers: shortcutModifiers, label: shortcutKeyLabel)
        storeShortcut(keyCode: keyCode, modifiers: modifiers, label: label)
        rejectedShortcut = nil
        if onShortcutChange?() != false { return true }
        rejectedShortcut = shortcutGlyphs
        storeShortcut(keyCode: old.keyCode, modifiers: old.modifiers, label: old.label)
        _ = onShortcutChange?()
        return false
    }

    private func storeShortcut(keyCode: UInt32, modifiers: UInt32, label: String) {
        shortcutKeyCode = keyCode
        shortcutModifiers = modifiers
        shortcutKeyLabel = label
        d.set(Int(keyCode), forKey: Keys.keyCode)
        d.set(Int(modifiers), forKey: Keys.modifiers)
        d.set(label, forKey: Keys.keyLabel)
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

/// An API key CopyPasta's features share (Copy Tricks and dictation use the same OpenRouter
/// key), in a private 0600 file under Application Support/CopyPasta/Credentials rather than
/// the Keychain: an ad-hoc signed app would hit a Keychain prompt after every rebuild.
/// If CopyPasta never had the key, the first read brings SuperSamuel's over (SuperSamuel
/// was the dictation app CopyPasta absorbed). A key the user cleared stays cleared.
struct SharedAPIKey {
    let store: CredentialStore
    /// Where SuperSamuel kept the same key; nil imports nothing (tests).
    let superSamuel: CredentialStore?

    static let openRouter = SharedAPIKey(account: "openrouter-api-key")
    static let openAI = SharedAPIKey(account: "openai-api-key")

    init(account: String) {
        self.init(
            store: CredentialStore(account: account),
            superSamuel: CredentialStore(
                service: SuperSamuelImport.bundleID, account: account,
                localDirectory: SuperSamuelImport.supportDirectory
                    .appendingPathComponent("Credentials", isDirectory: true)))
    }

    init(store: CredentialStore, superSamuel: CredentialStore? = nil) {
        self.store = store
        self.superSamuel = superSamuel
    }

    func read() -> String? {
        if let key = store.readAPIKey(useLocalStorage: true), !key.isEmpty { return key }
        guard !store.hasLocalAPIKeyFile,
              let key = superSamuel?.readAPIKey(useLocalStorage: true)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        try? store.writeAPIKey(key, useLocalStorage: true)
        return key
    }

    /// An empty key clears it.
    func write(_ key: String) throws {
        try store.writeAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines), useLocalStorage: true)
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
