import SwiftUI
import AppKit
import Carbon.HIToolbox
import Combine

struct SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case shortcuts = "Shortcuts"
        case dictation = "Dictation"
        case apiKeys = "API Keys"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general:    return "gearshape"
            case .shortcuts:  return "keyboard"
            case .dictation:  return "mic"
            case .apiKeys:    return "key"
            }
        }
    }

    @State private var pane: Pane? = .general
    /// Settings › Dictation's store; nil is the app's (a throwaway one in dev renders).
    private var dictationStore: SettingsStore? = nil

    /// The title bar's height (an empty unified toolbar makes it this tall, like Paste's):
    /// the window buttons sit in the sidebar, the pane's title level with them.
    static let titleBarHeight: CGFloat = 52
    static let background = Color(white: 0.125)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                Text((pane ?? .general).rawValue)
                    .font(.system(size: 15, weight: .bold))
                    .frame(height: Self.titleBarHeight)
                    .padding(.horizontal, 26)
                ScrollView {
                    Group {
                        switch pane ?? .general {
                        case .general:   GeneralPane()
                        case .shortcuts: ShortcutsPane()
                        case .dictation: DictationPane(store: dictationStore ?? .shared)
                        case .apiKeys:   APIKeysPane(store: dictationStore ?? .shared)
                        }
                    }
                    .padding(EdgeInsets(top: 2, leading: 24, bottom: 24, trailing: 24))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)   // Paste's compact switches and fields
            }
        }
        .background(Self.background)
        .ignoresSafeArea()
        .frame(minWidth: 680, minHeight: 560)
    }

    /// An inset panel down the left, holding the window buttons, like Paste's.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Pane.allCases) { p in
                SidebarRow(title: p.rawValue, icon: p.icon, selected: (pane ?? .general) == p) { pane = p }
            }
            Spacer(minLength: 12)
            SidebarRow(title: "Check for Updates…", icon: "arrow.triangle.2.circlepath", selected: false, small: true) {
                Updater.shared.checkForUpdates()
            }
            Text("Version \(Self.version)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.leading, 11)
                .padding(.top, 1)
        }
        .padding(EdgeInsets(top: Self.titleBarHeight - 4, leading: 7, bottom: 12, trailing: 7))
        .frame(width: 186)
        .frame(maxHeight: .infinity)
        .background(SidebarShape().fill(Color(white: 0.095)))
        .overlay(SidebarShape().stroke(.white.opacity(0.09), lineWidth: 1))
        .padding(7)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        return (info["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
    }
}

/// The sidebar's outline: its corners by the window's corners curve with them (concentric,
/// as in Paste); on macOS before 26, a plain rounded rectangle.
private struct SidebarShape: Shape {
    func path(in rect: CGRect) -> Path {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            return ConcentricRectangle(corners: .concentric(minimum: .fixed(12)), isUniform: false).path(in: rect)
        }
        #endif
        return RoundedRectangle(cornerRadius: 14, style: .continuous).path(in: rect)
    }
}

private struct SidebarRow: View {
    let title: String
    let icon: String
    let selected: Bool
    var small = false
    let action: () -> Void
    @State private var hovering = false
    /// In a window in the background, the selection turns gray, as in Paste and Finder.
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: small ? 12 : 13.5)).frame(width: 20)
            Text(title).font(.system(size: small ? 12 : 13)).lineLimit(1)
        }
        .foregroundStyle(selected && activeState != .inactive ? .white : .primary.opacity(small ? 0.75 : 0.9))
        .padding(.horizontal, 9)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? (activeState == .inactive ? Color.white.opacity(0.1) : .accentColor)
                           : .white.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
}

// MARK: - Reusable layout pieces (consistent sizing/alignment across panes)

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rounded grouped container like Paste's settings cards.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.16)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.05)))
    }
}

/// One full-width row: label leading, control trailing, fixed height.
private struct SettingRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 12)
    }
}

// MARK: - API Keys

/// Every key in one place: OpenRouter (Copy Tricks, dictation) and OpenAI (live
/// transcription). Saved as you type.
private struct APIKeysPane: View {
    private let store: SettingsStore
    @ObservedObject private var settings = AppSettings.shared
    @State private var openRouterKey: String
    @State private var openAIKey: String
    @State private var saveError: String?

    init(store: SettingsStore) {
        self.store = store
        _openRouterKey = State(initialValue: store.openRouterAPIKey)
        _openAIKey = State(initialValue: store.openAIAPIKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "OpenRouter")
                Card {
                    SettingRow(title: "API key") {
                        SecureField("sk-or-…", text: $openRouterKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    RowDivider()
                    SettingRow(title: "Copy Tricks model") {
                        TextField(AppSettings.defaultTextModel, text: $settings.textModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                }
                footnote("Needed for ⌘C C, ⌘C C C and dictation. The default Copy Tricks model goes to the fastest provider OpenRouter has for it, so results come back in well under a second.")
            }

            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "OpenAI")
                Card {
                    SettingRow(title: "API key") {
                        SecureField("sk-…", text: $openAIKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                }
                footnote("Only for live transcription (Dictation), which streams your voice to OpenAI so the text appears while you speak. An OpenRouter key can't open that connection.")
            }

            if let saveError {
                Text(saveError).font(.system(size: 11.5)).foregroundStyle(.red)
            } else {
                footnote("Your keys stay on this Mac, in files only you can read.")
            }
        }
        .onChange(of: openRouterKey) {
            store.openRouterAPIKey = openRouterKey
            saveError = store.credentialSaveError
        }
        .onChange(of: openAIKey) {
            store.openAIAPIKey = openAIKey
            saveError = store.credentialSaveError
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Dictation

/// Formerly SuperSamuel's settings window: every one of its settings, in CopyPasta's layout.
/// Values save as you edit and apply to the next recording.
private struct DictationPane: View {
    private let store: SettingsStore
    @State private var autoPaste: Bool
    @State private var restoreClipboard: Bool
    @State private var realtimeEnabled: Bool
    /// Read once: it's edited on the API Keys page, and switching pages rebuilds this one.
    private let hasOpenAIKey: Bool
    @State private var delay: TranscriptionDelay
    @State private var transcriptionModel: String
    @State private var cleanupEnabled: Bool
    @State private var cleanupModel: String
    @State private var cleanupInstructions: String
    @State private var dictionaryText: String
    @State private var dictionaryError: String?
    @State private var accessibilityGranted = Paster.isTrusted
    private let accessibilityPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(store: SettingsStore) {
        self.store = store
        _autoPaste = State(initialValue: store.autoPaste)
        _restoreClipboard = State(initialValue: store.restoreClipboard)
        _realtimeEnabled = State(initialValue: store.realtimeTranscriptionEnabled)
        hasOpenAIKey = !store.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        _delay = State(initialValue: store.transcriptionDelay)
        _transcriptionModel = State(initialValue: store.transcriptionModel)
        _cleanupEnabled = State(initialValue: store.cleanupEnabled)
        _cleanupModel = State(initialValue: store.cleanupModel)
        _cleanupInstructions = State(initialValue: store.cleanupInstructions)
        _dictionaryText = State(initialValue: store.personalDictionary.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Press \(AppSettings.shared.shortcut(.dictation).glyphs) in any app to start dictating, and again to stop. CopyPasta transcribes what you said and pastes it where you were. Each recording is saved first, so if a transcription fails you can retry it from the panel's Recordings tab.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Card {
                    SettingRow(title: "Paste the result into the active app") {
                        Toggle("", isOn: $autoPaste).labelsHidden().toggleStyle(.switch)
                    }
                    RowDivider()
                    SettingRow(title: "Restore the clipboard after pasting") {
                        Toggle("", isOn: $restoreClipboard).labelsHidden().toggleStyle(.switch)
                            .disabled(!autoPaste)
                    }
                    if autoPaste {
                        RowDivider()
                        SettingRow(title: "Accessibility access") {
                            if accessibilityGranted {
                                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Button("Grant Access…") { Paster.requestAccess() }
                            }
                        }
                    }
                }
                footnote("The transcript always goes on the clipboard. Pasting it for you needs Accessibility access; restoring puts back what you had copied before.")
            }
            .onReceive(accessibilityPoll) { _ in accessibilityGranted = Paster.isTrusted }

            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Live Transcription")
                Card {
                    SettingRow(title: "Use GPT Live Transcribe") {
                        Toggle("", isOn: $realtimeEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    RowDivider()
                    SettingRow(title: "Delay") {
                        Picker("", selection: $delay) {
                            ForEach(TranscriptionDelay.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    RowDivider()
                    SettingRow(title: "Status") {
                        Label(realtimeStatus, systemImage: realtimeReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(realtimeReady ? Color.green : Color.orange)
                    }
                }
                footnote("Streams your voice to OpenAI, so the text appears while you speak. It needs an OpenAI key (API Keys). A higher delay gives the model more audio before it shows text; the pause that ends a phrase stays at 500 ms.")
            }

            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Transcription")
                Card {
                    SettingRow(title: "Saved-audio model") {
                        TextField(OpenRouterService.transcriptionModel, text: $transcriptionModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                }
                footnote("When live transcription is off or fails, and when you retry a recording, the saved audio is transcribed with this model, through OpenRouter (its key is in API Keys). It must be a speech-to-text model, not a chat model such as Gemini.")
            }

            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Text Cleanup")
                Card {
                    SettingRow(title: "Clean up the transcript after Stop") {
                        Toggle("", isOn: $cleanupEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    if cleanupEnabled {
                        RowDivider()
                        SettingRow(title: "Model") {
                            TextField(OpenRouterService.defaultCleanupModel, text: $cleanupModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                        }
                    }
                }
                footnote(cleanupNote)
                if cleanupEnabled {
                    HStack {
                        Text("Editing instructions").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("Restore Default") { cleanupInstructions = OpenRouterService.defaultCleanupInstruction }
                            .disabled(cleanupInstructions == OpenRouterService.defaultCleanupInstruction)
                    }
                    .padding(.top, 4)
                    Card {
                        TextEditor(text: $cleanupInstructions)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(height: 220)
                    }
                    footnote("This is the whole prompt the cleanup model gets. Turn cleanup off to paste the transcription as it is.")
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Personal Dictionary")
                Card {
                    TextEditor(text: $dictionaryText)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 130)
                }
                if let dictionaryError {
                    Text(dictionaryError + " Your last valid dictionary is still saved.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Dictionary error: " + dictionaryError)
                } else {
                    footnote("One word or phrase per line: names, products, technical terms. They help the transcription spell them right. Blank lines and duplicates are ignored; the first spelling wins.")
                }
            }

            if store.superSamuelAudioLeftBehind {
                footnote("Your transcripts from SuperSamuel are in the panel's Recordings tab. Their audio was over 1 GB, so it stayed in \(SuperSamuelImport.supportDirectory.path).")
            }

            Spacer(minLength: 0)
        }
        .onChange(of: autoPaste) { store.autoPaste = autoPaste }
        .onChange(of: restoreClipboard) { store.restoreClipboard = restoreClipboard }
        .onChange(of: realtimeEnabled) { store.realtimeTranscriptionEnabled = realtimeEnabled }
        .onChange(of: delay) { store.transcriptionDelay = delay }
        .onChange(of: transcriptionModel) { store.transcriptionModel = transcriptionModel }
        .onChange(of: cleanupEnabled) { store.cleanupEnabled = cleanupEnabled }
        .onChange(of: cleanupModel) { store.cleanupModel = cleanupModel }
        .onChange(of: cleanupInstructions) { store.cleanupInstructions = cleanupInstructions }
        .onChange(of: dictionaryText) {
            do {
                // Pasted CRLF line endings would otherwise fail validation.
                let lines = dictionaryText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                try store.setPersonalDictionary(lines)
                dictionaryError = nil
            } catch {
                dictionaryError = error.localizedDescription
            }
        }
    }

    private var realtimeReady: Bool { realtimeEnabled && hasOpenAIKey }

    private var realtimeStatus: String {
        guard realtimeEnabled else { return "Off: the saved audio is transcribed after Stop" }
        return realtimeReady ? "Ready" : "Add an OpenAI key in API Keys"
    }

    private var cleanupNote: String {
        var note = "After transcription, a language model edits the text: it removes filler words and fixes punctuation, following the instructions below. It adds a short wait after Stop; your audio isn't sent to it."
        let model = cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanupEnabled, model.isEmpty || model == OpenRouterService.defaultCleanupModel {
            note += " The default model goes to the fastest provider OpenRouter has for it, with thinking off. If it's unavailable, your draft is kept so you can retry."
        } else if cleanupEnabled, model == "google/gemini-3.8-flash" {
            note += " Prefers Google AI Studio Priority at its higher rate, with a fallback if it's unavailable."
        }
        return note
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension SettingsView {
    /// Open on the pane named `pane` (the Recordings tab's Add Key…, `--render-settings`),
    /// with Dictation reading `store`.
    init(pane: String, dictationStore: SettingsStore) {
        _pane = State(initialValue: Pane(rawValue: pane) ?? .general)
        self.dictationStore = dictationStore
    }
}

#if DEBUG
extension SettingsView {
    /// `CopyPasta --render-settings <png> [--pane Dictation]`: Settings at its window size, in a
    /// window that's never shown. Dictation shows sample values from a throwaway store, not
    /// your settings or keys.
    @MainActor
    static func render(to path: String, pane: String) {
        NSApplication.shared.setActivationPolicy(.prohibited) // no Dock icon, no focus
        let suite = "copypasta-render-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let keys = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            SuperSamuelImport.removeDefaultsSuite(suite)
            try? FileManager.default.removeItem(at: keys)
        }
        let store = SettingsStore(
            defaults: defaults,
            credentials: SharedAPIKey(store: CredentialStore(service: suite, account: "openrouter", localDirectory: keys)),
            openAICredentials: SharedAPIKey(store: CredentialStore(service: suite, account: "openai", localDirectory: keys)))
        store.openRouterAPIKey = "sk-or-v1-0000000000000000"
        store.cleanupEnabled = true
        store.transcriptionDelay = .minimal
        try? store.setPersonalDictionary(["Claude Code", "Conductor", "tryblend.ai", "Vercel"])
        defaults.set(true, forKey: SuperSamuelImport.audioLeftBehindKey)

        let size = NSSize(width: 680, height: CommandLine.arguments.contains("--tall") ? 1700 : 600)
        NSApp.appearance = NSAppearance(named: .darkAqua) // as the real window (and its controls)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        // The real window paints its background behind the detail column; a capture doesn't.
        // The window buttons aren't drawn in a borderless capture: stand-ins where they sit.
        let host = NSHostingView(rootView: SettingsView(pane: pane, dictationStore: store)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    ForEach(["#FF5F57", "#FEBC2E", "#5A5A5A"], id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 12, height: 12) }
                }
                .padding(.leading, 21).padding(.top, 20)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
#endif

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var settings = AppSettings.shared
    // Nothing notifies us when the user flips the switch in System Settings; poll.
    @State private var accessibilityGranted = Paster.isTrusted
    private let accessibilityPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card {
                SettingRow(title: "Open at login") {
                    Toggle("", isOn: $settings.openAtLogin).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingRow(title: "Show in Menu Bar") {
                    Toggle("", isOn: $settings.showInMenuBar).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingRow(title: "Sound effects") {
                    Toggle("", isOn: $settings.soundEffects).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingRow(title: "Liquid Glass") {
                    Picker("", selection: $settings.glassStyle) {
                        ForEach(GlassStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Paste Items")
                Card {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 12) {
                            RadioOption(title: "To active app",
                                        detail: "Paste selected items straight into the app you're using.",
                                        selected: settings.pasteDirectly) { settings.pasteDirectly = true }
                            RadioOption(title: "To clipboard",
                                        detail: "Copy selected items to the clipboard, to paste yourself later.",
                                        selected: !settings.pasteDirectly) { settings.pasteDirectly = false }
                        }
                        Spacer(minLength: 0)
                        PasteIllustration(direct: settings.pasteDirectly)
                            .scaleEffect(0.74, anchor: .topTrailing)
                            .frame(width: 98, height: 68, alignment: .topTrailing)
                    }
                    .padding(12)
                    if settings.pasteDirectly {
                        RowDivider()
                        SettingRow(title: "Accessibility access") {
                            if accessibilityGranted {
                                Label("Granted", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Button("Grant Access…") { Paster.requestAccess() }
                            }
                        }
                    }
                }
                if settings.pasteDirectly && !accessibilityGranted {
                    Text("macOS only lets CopyPasta paste for you with Accessibility access. Until then, items are copied and you press ⌘V yourself.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onReceive(accessibilityPoll) { _ in accessibilityGranted = Paster.isTrusted }

            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Keep History")
                Card {
                    VStack(spacing: 12) {
                        Slider(value: keepBinding, in: 0...4, step: 1)
                            .tint(.accentColor)
                        HStack(spacing: 0) {
                            ForEach(KeepHistory.allCases, id: \.self) { k in
                                Text(k.label)
                                    .font(.system(size: 12))
                                    .foregroundStyle(k == settings.keepHistory ? Color.primary : Color.secondary)
                                    .frame(maxWidth: .infinity, alignment: edgeAlignment(k))
                            }
                        }
                    }
                    .padding(12)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // Push the first/last labels to the track ends so they sit under their ticks.
    private func edgeAlignment(_ k: KeepHistory) -> Alignment {
        switch k {
        case .day:     return .leading
        case .forever: return .trailing
        default:       return .center
        }
    }

    private var keepBinding: Binding<Double> {
        Binding(
            get: { Double(settings.keepHistory.rawValue) },
            set: { settings.keepHistory = KeepHistory(rawValue: Int($0.rounded())) ?? .month }
        )
    }
}

/// One of a set of choices: a radio button, a title, and what it does.
private struct RadioOption: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(selected ? Color.accentColor : .white.opacity(0.12))
                if selected { Circle().fill(.white).frame(width: 5.5, height: 5.5) }
            }
            .frame(width: 14, height: 14)
            .padding(.top, 1.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The two ways to paste, drawn: the panel's selected card going into the app's window,
/// or onto the clipboard.
private struct PasteIllustration: View {
    let direct: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#F6A04D"), Color(hex: "#D9531E")],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            // The app's window.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2.5) { ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.5)).frame(width: 3, height: 3) } }
                ForEach([44, 36, 40, 26], id: \.self) { w in
                    Capsule().fill(.white.opacity(0.75)).frame(width: CGFloat(w), height: 2)
                }
            }
            .padding(6)
            .frame(width: 60, height: 46, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.13)))
            .opacity(direct ? 1 : 0.45)
            .offset(x: 58, y: 10)
            // The clipboard.
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .opacity(direct ? 0 : 1)
                .offset(x: 22, y: 12)
            // The panel, its first card picked.
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 16, height: 14)
                ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 2.5).fill(.white.opacity(0.3)).frame(width: 16, height: 14) }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.28)))
            .offset(x: 8, y: 64)
            // Where it goes.
            Path { p in
                p.move(to: CGPoint(x: 21, y: 66))
                if direct { p.addQuadCurve(to: CGPoint(x: 55, y: 40), control: CGPoint(x: 24, y: 42)) }
                else { p.addQuadCurve(to: CGPoint(x: 30, y: 40), control: CGPoint(x: 18, y: 52)) }
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 6))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(direct ? -35 : -70))
                .position(direct ? CGPoint(x: 55, y: 40) : CGPoint(x: 30, y: 39))
        }
        .frame(width: 132, height: 92)
        .animation(.easeOutStrong(0.25), value: direct)
        .accessibilityHidden(true)
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    // Nothing notifies us when the user flips the switch in System Settings; poll.
    @State private var accessibilityGranted = Paster.isTrusted
    private let accessibilityPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                shortcutRow(.activate)
                RowDivider()
                SettingRow(title: "Edit Text") {
                    StaticShortcut(glyphs: "⌘E")
                }
                RowDivider()
                shortcutRow(.dictation)
            }

            if let error = settings.shortcutError {
                warning(error)
            }
            ForEach(ShortcutAction.allCases.filter(settings.unavailableShortcuts.contains), id: \.self) { action in
                warning("\(settings.shortcut(action).glyphs) is already used by another app, so \(action.title) won't work. Quit that app, or record a different shortcut.")
            }

            Text("Click a shortcut, then press the keys you want; esc cancels. Edit Text (⌘E) works on the selected item while the panel is open. Dictation works in any app.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Copy Tricks")
                Card {
                    SettingRow(title: "Translate, French ↔ English") {
                        StaticShortcut(glyphs: "⌘C C")
                        Toggle("", isOn: $settings.translateOnDoubleCopy).labelsHidden().toggleStyle(.switch)
                    }
                    RowDivider()
                    SettingRow(title: "Fix typos") {
                        StaticShortcut(glyphs: "⌘C C C")
                        Toggle("", isOn: $settings.fixTyposOnTripleCopy).labelsHidden().toggleStyle(.switch)
                    }
                    RowDivider()
                    SettingRow(title: "Accessibility access") {
                        if accessibilityGranted {
                            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Grant Access…") { Paster.requestAccess() }
                        }
                    }
                }
                Text("Select text, hold ⌘ and tap C twice to translate it, or three times to fix its typos. The result replaces your selection and goes on the clipboard; ⌘Z undoes it. Uses your OpenRouter key (API Keys).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onReceive(accessibilityPoll) { _ in accessibilityGranted = Paster.isTrusted }

            Spacer(minLength: 0)
        }
    }

    /// A rebindable shortcut, with a reset button once it's been changed.
    private func shortcutRow(_ action: ShortcutAction) -> some View {
        SettingRow(title: action.title) {
            let standard = action.defaultShortcut
            if settings.shortcut(action) != standard {
                Button { settings.setShortcut(standard, for: action) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Reset to \(standard.glyphs)")
                .accessibilityLabel("Reset \(action.title) to \(standard.glyphs)")
            }
            ShortcutRecorder(action: action).frame(width: 110, height: 22)
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11.5))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Non-editable shortcut pill (for fixed shortcuts like ⌘E), styled like the recorder.
private struct StaticShortcut: View {
    let glyphs: String
    var body: some View {
        Text(glyphs)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 110, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.10)))
    }
}

// MARK: - Shortcut recorder

struct ShortcutRecorder: NSViewRepresentable {
    let action: ShortcutAction
    func makeNSView(context: Context) -> RecorderView { RecorderView(action: action) }
    func updateNSView(_ nsView: RecorderView, context: Context) { nsView.refresh() }
}

/// Click it, then press the new shortcut; esc or a click elsewhere cancels. CopyPasta's
/// hotkeys are paused meanwhile, so their current keys can be pressed too.
final class RecorderView: NSView {
    private let action: ShortcutAction
    private let label = NSTextField(labelWithString: "")
    private var recording = false
    /// Modifiers held while recording, shown until a key completes the shortcut.
    private var held: UInt32 = 0
    private var monitors: [Any] = []
    private var resignKeyObserver: NSObjectProtocol?

    init(action: ShortcutAction) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(action.title) shortcut")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    deinit { stopRecording() }

    // Recording starts on a click (or Space / Return once tabbed to), not on focus: a window
    // can hand its first responder to this view by itself, and must not start a recording.
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { startRecording() }
    override func accessibilityPerformPress() -> Bool { startRecording(); return true }
    override func keyDown(with event: NSEvent) {
        if [kVK_Space, kVK_Return].contains(Int(event.keyCode)) { startRecording() } else { super.keyDown(with: event) }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    // However recording ends (another view takes focus, the pane changes, the window closes or
    // goes to the background), it ends here, so the hotkeys never stay paused.
    override func resignFirstResponder() -> Bool { stopRecording(); return true }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopRecording()
        super.viewWillMove(toWindow: newWindow)
    }

    private func startRecording() {
        guard !recording, let window, window.makeFirstResponder(self) else { return }
        recording = true
        held = 0
        AppSettings.shared.shortcutError = nil
        HotKey.isPaused = true
        // A local monitor sees each key press in CopyPasta before it's dispatched (⌘ combos
        // included, which would otherwise run menu commands); returning nil swallows it.
        if let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: { [weak self] event in
            guard let self, self.recording else { return event }
            if event.type == .flagsChanged {
                self.held = carbonModifiers(event.modifierFlags)
                self.refresh()
                return nil
            }
            return self.record(event) ? nil : event
        }) { monitors.append(keys) }
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            if let self, event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                self.cancel()
            }
            return event
        }) { monitors.append(clicks) }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.cancel() }
        refresh()
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
        HotKey.isPaused = false
        refresh()
    }

    private func cancel() {
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        stopRecording()
    }

    /// False: not taken as a shortcut, and the key press goes on to do what it normally does.
    private func record(_ event: NSEvent) -> Bool {
        let settings = AppSettings.shared
        if Int(event.keyCode) == kVK_Escape { settings.shortcutError = nil; cancel(); return true }
        let shortcut = Shortcut(keyCode: UInt32(event.keyCode),
                                modifiers: carbonModifiers(event.modifierFlags),
                                label: keyLabel(for: event))
        let problem = shortcut.problem(as: action, among: settings.shortcuts)
        if shortcut.modifiers == UInt32(cmdKey) { // the app's own commands: ⌘W closes the window…
            settings.shortcutError = problem
            cancel()
            return false
        }
        if let problem {
            settings.shortcutError = problem // say why, and keep listening for another
            NSSound.beep()
            return true
        }
        cancel() // hotkeys back first, so the new one is checked against the others in place
        if !settings.setShortcut(shortcut, for: action) { NSSound.beep() } // Settings says why
        return true
    }

    func refresh() {
        let glyphs = AppSettings.shared.shortcut(action).glyphs
        layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.15)).cgColor
        label.stringValue = !recording ? glyphs : held == 0 ? "Type shortcut…" : modifierGlyphs(held)
        label.textColor = recording && held == 0 ? .secondaryLabelColor : .labelColor
        setAccessibilityValue(recording ? "Type shortcut" : glyphs)
    }

    private func keyLabel(for event: NSEvent) -> String {
        if let special = specialKeyNames[UInt32(event.keyCode)] { return special }
        // The key on its own, as the layout types it: ⇧⌘1 is "1", not "!".
        if let ch = event.characters(byApplyingModifiers: []),
           let scalar = ch.unicodeScalars.first,
           scalar.value >= 0x20, !(0xF700...0xF8FF).contains(scalar.value) { // not a function-key code
            return ch.uppercased()
        }
        return "key\(event.keyCode)"
    }
}

private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var c: UInt32 = 0
    if flags.contains(.command) { c |= UInt32(cmdKey) }
    if flags.contains(.option)  { c |= UInt32(optionKey) }
    if flags.contains(.control) { c |= UInt32(controlKey) }
    if flags.contains(.shift)   { c |= UInt32(shiftKey) }
    return c
}
