import SwiftUI
import AppKit
import Carbon.HIToolbox
import Combine

struct SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case shortcuts = "Shortcuts"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general:   return "gearshape"
            case .shortcuts: return "keyboard"
            }
        }
    }

    @State private var pane: Pane? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { p in
                    Label(p.rawValue, systemImage: p.icon).tag(p)
                }
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            ScrollView {
                Group {
                    switch pane ?? .general {
                    case .general:   GeneralPane()
                    case .shortcuts: ShortcutsPane()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

// MARK: - Reusable layout pieces (consistent sizing/alignment across panes)

private struct PaneTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rounded grouped container like Paste's settings cards.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)))
    }
}

/// One full-width row: label leading, control trailing, fixed height.
private struct SettingRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 14))
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 16)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var settings = AppSettings.shared
    // Nothing notifies us when the user flips the switch in System Settings; poll.
    @State private var accessibilityGranted = Paster.isTrusted
    private let accessibilityPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PaneTitle(text: "General")

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

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "Pasting")
                Card {
                    SettingRow(title: "Paste directly into the active app") {
                        Toggle("", isOn: $settings.pasteDirectly).labelsHidden().toggleStyle(.switch)
                    }
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
                Text("Enter or double-click pastes the item into the app you were in. macOS only allows that with Accessibility access; without it, the item is copied and you press ⌘V yourself.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onReceive(accessibilityPoll) { _ in accessibilityGranted = Paster.isTrusted }

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "Keep History")
                Card {
                    VStack(spacing: 12) {
                        Slider(value: keepBinding, in: 0...4, step: 1)
                        HStack(spacing: 0) {
                            ForEach(KeepHistory.allCases, id: \.self) { k in
                                Text(k.label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(k == settings.keepHistory ? Color.primary : Color.secondary)
                                    .frame(maxWidth: .infinity, alignment: edgeAlignment(k))
                            }
                        }
                    }
                    .padding(16)
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

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle(text: "Shortcuts")

            Card {
                SettingRow(title: "Activate Pastey") {
                    ShortcutRecorder().frame(width: 132, height: 28)
                }
                RowDivider()
                SettingRow(title: "Edit Text") {
                    StaticShortcut(glyphs: "⌘E")
                }
            }

            if let rejected = settings.rejectedShortcut, rejected != settings.shortcutGlyphs {
                warning("\(rejected) is already used by another app, so Pastey kept \(settings.shortcutGlyphs). Record a different shortcut, or quit that app first.")
            }
            if settings.shortcutUnavailable {
                warning("\(settings.shortcutGlyphs) is already used by another app (Paste, Maccy, …), so it won't open Pastey. Quit that app or record a different shortcut.")
            }

            Text("Activate Pastey is rebindable — click the field, then press the keys you want (needs a modifier; esc cancels). Edit Text (⌘E) works on the selected item while the panel is open.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Reset to Default (\(AppSettings.defaultGlyphs))") { settings.resetShortcut() }
                .controlSize(.large)

            Spacer(minLength: 0)
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Non-editable shortcut pill (for fixed shortcuts like ⌘E), styled like the recorder.
private struct StaticShortcut: View {
    let glyphs: String
    var body: some View {
        Text(glyphs)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 132, height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.10)))
    }
}

// MARK: - Shortcut recorder

struct ShortcutRecorder: NSViewRepresentable {
    func makeNSView(context: Context) -> RecorderView { RecorderView() }
    func updateNSView(_ nsView: RecorderView, context: Context) { nsView.refresh() }
}

final class RecorderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var monitor: Any?
    private var recording = false { didSet { refresh() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    // A local key-down monitor is the reliable way to capture inside a SwiftUI-hosted
    // view: it sees every key-down (incl. ⌘ combos, which would otherwise fire as
    // key equivalents / paste) BEFORE dispatch, and returning nil consumes them so
    // nothing leaks to whatever app is frontmost while recording.
    override func becomeFirstResponder() -> Bool {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.recording else { return event }
            self.record(event)
            return nil
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopMonitor()
        recording = false
        return true
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    deinit { stopMonitor() }

    private func record(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {          // cancel, keep current
            window?.makeFirstResponder(nil)
            return
        }
        let modifiers = carbonModifiers(event.modifierFlags)
        guard modifiers != 0 else { NSSound.beep(); return }   // ignore bare keys, stay recording
        let saved = AppSettings.shared.setShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            label: keyLabel(for: event)
        )
        if !saved { NSSound.beep() }   // another app holds it; Settings says so
        window?.makeFirstResponder(nil)
    }

    func refresh() {
        layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.15)).cgColor
        label.stringValue = recording ? "Type shortcut…" : AppSettings.shared.shortcutGlyphs
        label.textColor = recording ? .secondaryLabelColor : .labelColor
    }

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if flags.contains(.command) { c |= UInt32(cmdKey) }
        if flags.contains(.option)  { c |= UInt32(optionKey) }
        if flags.contains(.control) { c |= UInt32(controlKey) }
        if flags.contains(.shift)   { c |= UInt32(shiftKey) }
        return c
    }

    private func keyLabel(for event: NSEvent) -> String {
        if let special = specialKeyNames[UInt32(event.keyCode)] { return special }
        if let ch = event.charactersIgnoringModifiers,
           let scalar = ch.unicodeScalars.first, scalar.value >= 0x20 {
            return ch.uppercased()
        }
        return "key\(event.keyCode)"
    }
}
