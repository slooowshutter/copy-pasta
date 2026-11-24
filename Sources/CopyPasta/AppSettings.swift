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

/// A global shortcut: a Carbon key code and modifier mask, plus the key as the keyboard
/// typed it when recorded (so the label is right on any layout).
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    /// e.g. "⌥⇧⌘Space", for menus and Settings.
    var glyphs: String { modifierGlyphs(modifiers) + label }

    /// Why this can't be `action`'s shortcut, or nil if it can.
    func problem(as action: ShortcutAction, among current: [ShortcutAction: Shortcut]) -> String? {
        if !functionKeyCodes.contains(keyCode), modifiers & UInt32(cmdKey | optionKey | controlKey) == 0 {
            return "Add ⌘, ⌥ or ⌃ to it: without one, the shortcut would get in the way of typing."
        }
        if modifiers == UInt32(cmdKey) {
            return "\(glyphs) belongs to the app you're in (apps use ⌘ and a key for their own commands). Add ⌥, ⌃ or ⇧ to it."
        }
        if let other = current.first(where: {
            $0.key != action && $0.value.keyCode == keyCode && $0.value.modifiers == modifiers
        })?.key {
            return "\(glyphs) is already \(other.title)'s shortcut."
        }
        return nil
    }
}

/// CopyPasta's rebindable global shortcuts.
enum ShortcutAction: String, CaseIterable {
    // Raw values prefix the UserDefaults keys: "shortcutKeyCode"… is Activate's from before
    // dictation had one.
    case activate = "shortcut"
    case dictation = "dictationShortcut"

    var title: String {
        switch self {
        case .activate:  return "Activate CopyPasta"
        case .dictation: return "Start / Stop Dictation"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .activate:
            return Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), label: "V")
        case .dictation: // ⌥Space is left to SuperSamuel while it's still installed
            return Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey | cmdKey), label: "Space")
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
    /// Re-registers that action's global hotkey with its saved shortcut; false if another app holds it.
    var onShortcutChange: ((ShortcutAction) -> Bool)?

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

    // Changed only through setShortcut, so the hotkey is re-registered whenever one changes.
    @Published private(set) var shortcuts: [ShortcutAction: Shortcut] = [:]
    /// Runtime only: shortcuts another app already holds (set by AppDelegate), so they don't fire.
    @Published var unavailableShortcuts: Set<ShortcutAction> = []
    /// Runtime only: why the last shortcut recorded in Settings wasn't kept.
    @Published var shortcutError: String?

    private let d = UserDefaults.standard
    private enum Keys {
        static let menuBar = "showInMenuBar"
        static let sound = "soundEffects"
        static let pasteDirectly = "pasteDirectly"
        static let glassStyle = "glassStyle"
        static let keepHistory = "keepHistory"
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
        translateOnDoubleCopy = d.bool(forKey: Keys.translate)
        fixTyposOnTripleCopy = d.bool(forKey: Keys.fixTypos)
        textModel = d.string(forKey: Keys.textModel) ?? Self.defaultTextModel
        shortcuts = Self.loadShortcuts(d)
    }

    /// The saved shortcuts. One that's no longer allowed (an older version could save ⌘W, which
    /// then took ⌘W from every app) goes back to its default.
    static func loadShortcuts(_ d: UserDefaults) -> [ShortcutAction: Shortcut] {
        var shortcuts: [ShortcutAction: Shortcut] = [:]
        for action in ShortcutAction.allCases {
            let key = action.rawValue
            if d.object(forKey: key + "KeyCode") != nil, let label = d.string(forKey: key + "KeyLabel") {
                let saved = Shortcut(keyCode: UInt32(d.integer(forKey: key + "KeyCode")),
                                     modifiers: UInt32(d.integer(forKey: key + "Modifiers")), label: label)
                if saved.problem(as: action, among: shortcuts) == nil {
                    shortcuts[action] = saved
                    continue
                }
                plog("shortcut \(saved.glyphs) for \(action.title) isn't allowed; back to the default")
                ["KeyCode", "Modifiers", "KeyLabel"].forEach { d.removeObject(forKey: key + $0) }
            }
            shortcuts[action] = action.defaultShortcut
        }
        return shortcuts
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

    func shortcut(_ action: ShortcutAction) -> Shortcut { shortcuts[action] ?? action.defaultShortcut }

    /// Saves and registers `shortcut` for `action`. If it's not allowed, or another app already
    /// holds it, keeps the current one instead (rather than leave the action with none), sets
    /// `shortcutError`, and returns false.
    @discardableResult
    func setShortcut(_ shortcut: Shortcut, for action: ShortcutAction) -> Bool {
        if let problem = shortcut.problem(as: action, among: shortcuts) {
            shortcutError = problem
            return false
        }
        let old = self.shortcut(action)
        storeShortcut(shortcut, for: action)
        shortcutError = nil
        if onShortcutChange?(action) != false { return true }
        shortcutError = "\(shortcut.glyphs) is already used by another app, so \(action.title) keeps \(old.glyphs). Record a different shortcut, or quit that app first."
        storeShortcut(old, for: action)
        _ = onShortcutChange?(action)
        return false
    }

    private func storeShortcut(_ shortcut: Shortcut, for action: ShortcutAction) {
        shortcuts[action] = shortcut
        d.set(Int(shortcut.keyCode), forKey: action.rawValue + "KeyCode")
        d.set(Int(shortcut.modifiers), forKey: action.rawValue + "Modifiers")
        d.set(shortcut.label, forKey: action.rawValue + "KeyLabel")
    }

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

/// F1–F20, in order. The only keys a shortcut may use without ⌘, ⌥ or ⌃.
let functionKeyCodes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
    .map(UInt32.init)

/// Non-printable keys shown as glyphs; printable keys are named by what the keyboard layout
/// types for them, at record time.
let specialKeyNames: [UInt32: String] = Dictionary(
    uniqueKeysWithValues: functionKeyCodes.enumerated().map { ($1, "F\($0 + 1)") }
).merging([
    UInt32(kVK_ANSI_KeypadEnter): "⌤",
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
]) { $1 }
