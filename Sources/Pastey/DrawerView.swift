import SwiftUI
import AppKit

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst(hex.hasPrefix("#") ? 1 : 0))).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension Board {
    static let presetColors = [
        "#FFC53D", "#FF8A3D", "#FF5D5D", "#FF6BB5",
        "#9B6BFF", "#4D8DFF", "#2FBFAF", "#3DBF6B",
    ]
    static let presetColorNames = [
        "Yellow", "Orange", "Red", "Pink",
        "Purple", "Blue", "Teal", "Green",
    ]
    var color: Color { Color(hex: colorHex) }

    /// Colored dot for menu items (a plain SF Symbol would be tinted monochrome).
    static func swatch(_ hex: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(Color(hex: hex)).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct DrawerView: View {
    @ObservedObject var state: DrawerState
    unowned let ctrl: PanelController
    @ObservedObject private var settings = AppSettings.shared

    @FocusState private var editorFocused: Bool
    @State private var scrolledID: Int64?

    // Panel background: Liquid Glass when the setting is on and the OS + SDK support it,
    // otherwise the classic HUD material. The compiler guard lets this file build on the
    // pre-26 SDK too (glassEffect only exists in the macOS 26 SDK).
    @ViewBuilder private var panelBackground: some View {
        #if compiler(>=6.2)
        if settings.glassStyle != .off, #available(macOS 26, *) {
            // .clear = more see-through / liquid; .regular = frostier, more opaque.
            Color.clear.glassEffect(settings.glassStyle == .clear ? Glass.clear : Glass.regular,
                                    in: RoundedRectangle(cornerRadius: 18))
        } else {
            VisualEffect()
        }
        #else
        VisualEffect()
        #endif
    }

    var body: some View {
        ZStack {
            panelBackground
            VStack(spacing: 10) {
                topBar
                if state.items.isEmpty {
                    Spacer()
                    Text(emptyMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    cards
                }
                Text(hintText)
                    .font(.system(size: 11))
                    .foregroundStyle(state.selectedIndices.count > 1 ? .secondary : .tertiary)
                    .padding(.bottom, 8)
            }
            .padding(.top, 12)

            if state.editingItem != nil { editorOverlay }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.15), value: state.editingItem)
    }

    // MARK: - Inline text editor (⌘E)

    private var editorOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)   // blocks the cards behind; Cancel/Save/esc to dismiss
            VStack(spacing: 0) {
                HStack {
                    Button("Cancel") { ctrl.cancelEdit() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") { ctrl.saveEdit() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .padding(12)

                TextEditor(text: $state.editText)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.10)))
                    .padding(.horizontal, 12)

                Text("\(state.editText.count) characters")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(width: 480, height: 300)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.13)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
            .shadow(radius: 30)
            .onAppear { DispatchQueue.main.async { editorFocused = true } }
        }
    }

    private var hintText: String {
        let n = state.selectedIndices.count
        if n > 1 {
            return "\(n) selected   ⇧← → adjust   ⏎ paste all\(state.searchOpen ? "" : "   ⌘⌫ delete")   esc"
        }
        if state.searchOpen { return "← → navigate   ⇧← → multiselect   ⏎ paste   ⌘E edit   esc clear search" }
        return "type to search   ← → navigate   ⇧← → multiselect   ⌘← ⌘→ boards   ⏎ paste   ⌘E edit   esc close"
    }

    private var emptyMessage: String {
        if !state.query.isEmpty { return "No matches" }
        return state.currentBoardID == nil
            ? "Copy something to get started"
            : "Right-click any card → Pin to… to fill this board"
    }

    // MARK: - Top bar — one centered group: 🔍 · tabs · +   (like Paste)

    private var topBar: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 8)
            if state.searchOpen {
                // Search takes over the width (capped), categories hidden.
                searchField.frame(maxWidth: 640)
            } else {
                iconButton("magnifyingglass", help: "Search") { state.searchOpen = true }
                TabChip(label: "Clipboard", icon: "clock.arrow.circlepath", dot: nil,
                        isCurrent: state.currentBoardID == nil) { ctrl.activateBoard(nil) }
                ForEach(state.boards) { board in
                    BoardChip(board: board, isCurrent: state.currentBoardID == board.id,
                              isRenaming: state.renamingBoardID == board.id, ctrl: ctrl)
                }
                iconButton("plus", help: "New pinboard") { ctrl.createBoard() }
            }
            Spacer(minLength: 8)
        }
        .frame(height: 40)
        .padding(.horizontal, 12)
        // Pinned top-right without disturbing the centered cluster.
        .overlay(alignment: .trailing) {
            if !state.searchOpen { ellipsisMenu.padding(.trailing, 12) }
        }
    }

    private var ellipsisMenu: some View {
        Menu {
            Menu(state.isPaused ? "Paused" : "Pause Pastey") {
                Button("Pause for 15 minutes") { ctrl.pause(for: 15 * 60) }
                Button("Pause for 30 minutes") { ctrl.pause(for: 30 * 60) }
                Button("Pause for 1 hour")     { ctrl.pause(for: 60 * 60) }
                Button("Pause for 3 hours")    { ctrl.pause(for: 3 * 60 * 60) }
                Button("Pause for 8 hours")    { ctrl.pause(for: 8 * 60 * 60) }
                Divider()
                Button(state.isPaused ? "Resume Pastey" : "Pause Pastey") { ctrl.togglePause() }
            }
            Divider()
            Button("Settings…") { ctrl.openSettings() }
            Divider()
            Button("Quit Pastey") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
            PanelTextField(text: $state.query, placeholder: "Search \(state.currentBoard?.name ?? "Clipboard")…")
            Button { state.searchOpen = false; state.query = "" } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Cards

    private var cards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 20) {
                ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                    CardView(item: item, selected: state.selectedIndices.contains(index), boardColor: state.currentBoard?.color)
                        .id(item.id)
                        .onTapGesture { ctrl.cardClicked(at: index) }
                        .contextMenu { cardMenu(for: item) }
                        .onAppear {
                            // Infinite scroll: fetch the next page as the end comes into view.
                            if index >= state.items.count - 20 { state.loadMore() }
                        }
                }
            }
            .scrollTargetLayout()
        }
        // Reserves consistent room at both scroll extremes so the first/last card
        // always keeps its gap (fixes missing-left-pad and collapsing-right-gap).
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .contentMargins(.vertical, 6, for: .scrollContent)
        .scrollPosition(id: $scrolledID, anchor: .center)
        .onChange(of: state.selection) {
            guard state.items.indices.contains(state.selection) else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                scrolledID = state.items[state.selection].id
            }
        }
        .onChange(of: state.shownTick) { scrolledID = state.items.first?.id }
    }

    @ViewBuilder
    private func cardMenu(for item: ClipItem) -> some View {
        Button("Paste") { ctrl.paste([item]) }
        Button("Copy") { ctrl.copy(item) }
        Divider()
        Menu("Pin to") {
            ForEach(state.boards) { board in
                Button(board.name) { ctrl.pin(item, to: board.id) }
            }
            if !state.boards.isEmpty { Divider() }
            Button("New Pinboard") { ctrl.pinToNewBoard(item) }
        }
        Divider()
        Button("Delete", role: .destructive) { ctrl.deleteItem(item) }
    }
}

// MARK: - Tabs

/// A tab label whose width is fixed to its *bold* size, so toggling the weight
/// on selection never changes its footprint — the row stays put (no shift).
struct TabLabel: View {
    var icon: String? = nil
    var dot: Color? = nil
    let text: String
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 13)) }
            if let dot { Circle().fill(dot).frame(width: 10, height: 10) }
            // ZStack sizes to its widest child (the hidden bold copy), so the
            // visible text can switch weight without changing the cell width.
            ZStack {
                Text(text).font(.system(size: 15, weight: .semibold)).hidden()
                Text(text).font(.system(size: 15, weight: isCurrent ? .semibold : .regular)).lineLimit(1)
            }
            .fixedSize()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(isCurrent ? .white.opacity(0.14) : .clear))
        .contentShape(Rectangle())
    }
}

struct TabChip: View {
    let label: String
    var icon: String? = nil
    var dot: Color? = nil
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        TabLabel(icon: icon, dot: dot, text: label, isCurrent: isCurrent)
            .onTapGesture(perform: action)
    }
}

/// Click to open; click the open board again (or right-click › Rename) to rename it
/// in place. Everything else lives in the right-click menu. No popover: it's its own
/// window, and focusing its text field would activate Pastey and close the panel.
struct BoardChip: View {
    let board: Board
    let isCurrent: Bool
    let isRenaming: Bool
    unowned let ctrl: PanelController

    var body: some View {
        Group {
            if isRenaming {
                BoardNameField(board: board, ctrl: ctrl)
            } else {
                TabLabel(dot: board.color, text: board.name, isCurrent: isCurrent)
                    .onTapGesture {
                        if isCurrent {
                            ctrl.beginRename(board.id)
                        } else {
                            ctrl.activateBoard(board.id)
                        }
                    }
            }
        }
        .contextMenu {
            Button("Rename") { ctrl.beginRename(board.id) }
            Menu("Color") {
                ForEach(Array(zip(Board.presetColors, Board.presetColorNames)), id: \.0) { preset in
                    Button { ctrl.recolorBoard(board.id, to: preset.0) } label: {
                        Label { Text(preset.1) } icon: { Image(nsImage: Board.swatch(preset.0)) }
                    }
                }
            }
            Divider()
            Button("Delete Pinboard", role: .destructive) { ctrl.deleteBoard(board.id) }
        }
    }
}

/// The chip in rename mode: same footprint, name field instead of the label.
private struct BoardNameField: View {
    let board: Board
    unowned let ctrl: PanelController
    @State private var name: String

    init(board: Board, ctrl: PanelController) {
        self.board = board
        self.ctrl = ctrl
        _name = State(initialValue: board.name)
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(board.color).frame(width: 10, height: 10)
            PanelTextField(text: $name, placeholder: "Board name", selectsAllOnFocus: true,
                           onSubmit: { ctrl.finishRename(board.id, to: name) },
                           onCancel: { ctrl.finishRename(board.id, to: nil) })
                .frame(width: 140)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.14)))
    }
}

// MARK: - Text field

/// AppKit-backed single-line field (search, board rename) that takes focus as soon as
/// it appears. SwiftUI's TextField can't place the caret when focused in code (it
/// selects everything), which would eat type-to-search's first keystroke.
struct PanelTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var selectsAllOnFocus = false
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    func makeNSView(context: Context) -> AutoFocusTextField {
        let field = AutoFocusTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = .systemFont(ofSize: 15)
        field.selectsAllOnFocus = selectsAllOnFocus
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: AutoFocusTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    /// Fill the offered width (like TextField); height from the font.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AutoFocusTextField, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 200
        return CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PanelTextField
        init(parent: PanelTextField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ note: Notification) {
            parent.onSubmit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

final class AutoFocusTextField: NSTextField {
    var selectsAllOnFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Next turn: SwiftUI is still mid-update when it inserts us.
        DispatchQueue.main.async { [weak self] in self?.takeFocus() }
    }

    /// Take keyboard focus: all text selected if `selectsAllOnFocus`, otherwise the
    /// caret after any typed-ahead text.
    func takeFocus() {
        guard let window, window.makeFirstResponder(self) else { return }
        if !selectsAllOnFocus {
            // makeFirstResponder selects all; move the caret to the end instead.
            let end = (stringValue as NSString).length
            currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
    }
}

// MARK: - Card

struct CardView: View {
    let item: ClipItem
    let selected: Bool
    var boardColor: Color?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(width: 256, height: 242)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.accentColor : .white.opacity(0.08),
                              lineWidth: selected ? 3 : 1)
        )
        .scaleEffect(selected ? 1.0 : 0.98)
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private var header: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(Self.relative.localizedString(for: item.createdAt, relativeTo: Date()))
                    .font(.system(size: 12))
                    .opacity(0.75)
            }
            Spacer()
            if let icon = Self.appIcon(for: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26, height: 26)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .frame(maxWidth: .infinity)
        .background(boardColor ?? kindColor)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text, .link:
            Text(item.plainText?.prefix(500) ?? "")
                .font(.system(size: textFontSize))
                .foregroundStyle(item.kind == .link ? Color(red: 0.4, green: 0.65, blue: 1) : .primary)
                .multilineTextAlignment(.leading)
                .padding(13)
        case .image:
            if let nsImage = Self.thumbImage(for: item) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 256, height: 160)
                    .clipped()
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .file:
            VStack(spacing: 8) {
                if let first = item.filePaths.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first))
                        .resizable()
                        .frame(width: 56, height: 56)
                }
                Text(item.filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"))
                    .font(.system(size: 13.5))
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)
        }
    }

    /// Short snippets render large and fill the card; long text shrinks to stay
    /// readable — mirrors how Paste sizes its previews.
    private var textFontSize: CGFloat {
        switch item.plainText?.count ?? 0 {
        case 0..<22: return 23
        case 22..<55: return 18
        case 55..<150: return 15
        default: return 13
        }
    }

    private var footer: some View {
        Text(meta)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(Color.black.opacity(0.25))
    }

    // The header shows the *type* only (like Paste); the content lives in the body.
    private var title: String {
        switch item.kind {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return item.filePaths.count > 1 ? "\(item.filePaths.count) Files" : "File"
        }
    }

    private var meta: String {
        switch item.kind {
        case .text, .link:
            return "\(item.charCount) characters"
        case .image:
            return item.pixelW > 0 ? "\(item.pixelW) × \(item.pixelH)" : "Image"
        case .file:
            return item.filePaths.count == 1 ? "1 file" : "\(item.filePaths.count) files"
        }
    }

    private var kindColor: Color {
        switch item.kind {
        case .text: Color(red: 0.20, green: 0.22, blue: 0.25)
        case .link: Color(red: 0.15, green: 0.42, blue: 0.85)
        case .image: Color(red: 0.42, green: 0.30, blue: 0.80)
        case .file: Color(red: 0.13, green: 0.52, blue: 0.35)
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    // Decoding NSImage(data:) inside body creates a fresh image identity every
    // render, which SwiftUI crossfades under .animation — the "overlay flash"
    // bug. A stable cached instance renders with no transition.
    private static let thumbCache = NSCache<NSNumber, NSImage>()

    static func thumbImage(for item: ClipItem) -> NSImage? {
        let key = NSNumber(value: item.id)
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let data = item.thumb, let image = NSImage(data: data) else { return nil }
        thumbCache.setObject(image, forKey: key)
        return image
    }

    private static var iconCache: [String: NSImage] = [:]

    static func appIcon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
