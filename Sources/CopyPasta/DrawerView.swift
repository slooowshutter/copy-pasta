import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

extension Animation {
    /// Emil Kowalski's "strong ease-out": moves at once, then settles. For UI motion that
    /// answers an action (reflow after a delete, scrolling to the selection).
    static func easeOutStrong(_ duration: Double = 0.2) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
}

/// Like Paste's, the panel floats a little off the screen's sides and bottom, every corner
/// rounded. The gap is see-through: a click there goes to the app behind, closing the panel.
let panelShape = RoundedRectangle(cornerRadius: 20, style: .continuous)
let panelInset: CGFloat = 8

struct DrawerView: View {
    @ObservedObject var state: DrawerState
    unowned let ctrl: PanelController
    @ObservedObject private var settings = AppSettings.shared

    @FocusState private var editorFocused: Bool
    @State private var scrolledID: Int64?
    @State private var scrolledRecordingID: UUID?

    // Panel background: Liquid Glass when the setting is on and the OS + SDK support it,
    // otherwise the classic HUD material. The compiler guard lets this file build on the
    // pre-26 SDK too (glassEffect only exists in the macOS 26 SDK).
    @ViewBuilder private var panelBackground: some View {
        #if compiler(>=6.2)
        if settings.glassStyle != .off, #available(macOS 26, *) {
            // .clear = more see-through / liquid; .regular = frostier, more opaque.
            Color.clear.glassEffect(settings.glassStyle == .clear ? Glass.clear : Glass.regular,
                                    in: panelShape)
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
            // macOS hands clicks on fully transparent pixels of a window to the window
            // behind it, and the glass and HUD materials are drawn outside the window's
            // own pixels: between and around the ••• dots, a click went to the app below
            // (its text cursor showed) and the panel closed. A faint fill keeps every
            // pixel the panel's.
            Color.black.opacity(0.02)
            VStack(spacing: 8) {
                topBar
                if state.count == 0 {
                    Spacer()
                    Text(emptyMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer()
                } else if state.showingRecordings {
                    recordingCards
                } else {
                    cards
                }
                Text(hintText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(state.selectedIndices.count > 1 ? .secondary : .tertiary)
                    .padding(.bottom, 8)
            }
            .padding(.top, 12)

            if state.editingItem != nil { editorOverlay }
        }
        .clipShape(panelShape)
        .overlay(panelShape.strokeBorder(.white.opacity(0.12), lineWidth: 1))   // a hairline all round
        .padding(EdgeInsets(top: 0, leading: panelInset, bottom: panelInset, trailing: panelInset))
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
            return "\(n) selected   ⇧← → adjust   ⏎ paste all   ⌘C copy all\(state.searchOpen ? "" : "   ⌘⌫ delete")   esc"
        }
        if state.showingRecordings { return RecordingsTab.hint }
        if state.searchOpen { return "← → navigate   ⇧← → multiselect   ⏎ paste   ⌘E edit   esc clear search" }
        return "type to search   ← → navigate   ⇧← → multiselect   ⌘← ⌘→ boards   ⏎ paste   ⌘E edit   esc close"
    }

    private var emptyMessage: String {
        if !state.query.isEmpty { return "No matches" }
        if state.showingRecordings { return "No recordings yet. Press \(AppSettings.shared.shortcut(.dictation).glyphs) to dictate." }
        return state.currentBoardID == nil
            ? "Copy something to get started"
            : "Drag a card onto this tab, or right-click it › Pin to"
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
                        isCurrent: state.currentBoardID == nil && !state.showingRecordings) { ctrl.activateBoard(nil) }
                ForEach(state.boards) { board in
                    BoardChip(board: board, isCurrent: state.currentBoardID == board.id,
                              isRenaming: state.renamingBoardID == board.id, ctrl: ctrl)
                }
                RecordingsTab(isCurrent: state.showingRecordings)
                    .onTapGesture { ctrl.showRecordings() }
                iconButton("plus", help: "New pinboard") { ctrl.createBoard() }
            }
            Spacer(minLength: 8)
        }
        .frame(height: 34)
        .padding(.horizontal, 12)
        // Pinned to the corners without disturbing the centered cluster.
        .overlay(alignment: .leading) { brand.padding(.leading, 18) }
        .overlay(alignment: .trailing) {
            if !state.searchOpen { ellipsisMenu.padding(.trailing, 6) }
        }
    }

    private var ellipsisMenu: some View {
        Button { ctrl.showMoreMenu() } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 30)
                .padding(6)                  // a bigger target than it looks
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("More")
    }

    /// Top-left: which app this is (it looks a lot like Paste).
    private var brand: some View {
        HStack(spacing: 7) {
            if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 18, height: 18)
            }
            Text("CopyPasta").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
            PanelTextField(text: $state.query, placeholder: "Search \(state.showingRecordings ? "Recordings" : state.currentBoard?.name ?? "Clipboard")…")
            Button { state.searchOpen = false; state.query = "" } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.08)))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Cards

    private var cards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 14) {   // + the cards' 3pt ring margins = a 20pt gap
                ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                    CardView(item: item, selected: state.selectedIndices.contains(index), boardColor: state.currentBoard?.color)
                        .id(item.id)
                        .onTapGesture { ctrl.cardClicked(at: index) }
                        .onDrag { ctrl.beginDrag(item, at: index) }
                        .contextMenu { cardMenu(for: item, at: index) }
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
        .contentMargins(.horizontal, 17, for: .scrollContent)
        .contentMargins(.vertical, 4, for: .scrollContent)
        .scrollPosition(id: $scrolledID, anchor: .center)
        .onChange(of: state.selection) {
            guard state.items.indices.contains(state.selection) else { return }
            withAnimation(.easeOutStrong(0.18)) {
                scrolledID = state.items[state.selection].id
            }
        }
        .onChange(of: state.shownTick) { scrolledID = state.items.first?.id }
    }

    /// The Recordings tab's cards (RecordingCards.swift): one per dictation.
    private var recordingCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 14) {
                ForEach(Array(state.recordings.enumerated()), id: \.element.id) { index, card in
                    Group {
                        if card.status == .recording || card.status == .transcribing,
                           let live = (NSApp.delegate as? AppDelegate)?.dictation.liveState {
                            LiveRecordingCard(card: card, live: live, selected: state.selectedIndices.contains(index))
                        } else {
                            RecordingCardView(card: card, selected: state.selectedIndices.contains(index),
                                              playback: state.playingID == card.id ? ctrl.playback : nil) { ctrl.perform($0, on: card) }
                        }
                    }
                        .id(card.id)
                        .onTapGesture { ctrl.recordingClicked(at: index) }
                        .contextMenu { recordingMenu(for: card) }
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 17, for: .scrollContent)
        .contentMargins(.vertical, 4, for: .scrollContent)
        .scrollPosition(id: $scrolledRecordingID, anchor: .center)
        .onChange(of: state.selection) {
            guard state.recordings.indices.contains(state.selection) else { return }
            withAnimation(.easeOutStrong(0.18)) { scrolledRecordingID = state.recordings[state.selection].id }
        }
        .onChange(of: state.shownTick) { scrolledRecordingID = state.recordings.first?.id }
    }

    @ViewBuilder
    private func recordingMenu(for card: RecordingCard) -> some View {
        if card.status == .transcribed {
            Button("Copy") { ctrl.perform(.copy, on: card) }
            Button("Duplicate") { ctrl.perform(.duplicate, on: card) }
        }
        if card.audioBytes > 0 {
            Button(state.playingID == card.id ? "Stop" : "Play Recording") { ctrl.perform(.play, on: card) }
        }
        if let primary = card.primary { Button(primary.label) { ctrl.perform(primary.action, on: card) } }
        if card.needsAttention, card.words > 0, card.primary?.action != .copyDraft {
            Button("Copy Draft") { ctrl.perform(.copyDraft, on: card) }
        }
        Divider()
        Button("Show in Finder") { ctrl.perform(.reveal, on: card) }
        Button("Move to Trash", role: .destructive) { ctrl.perform(.trash, on: card) }
            .disabled(card.status == .recording || card.status == .transcribing)
    }

    @ViewBuilder
    private func cardMenu(for item: ClipItem, at index: Int) -> some View {
        // Right-clicking a card in a multi-selection acts on all of it, like Finder.
        let targets = ctrl.targets(forCardAt: index)
        let count = targets.count > 1 ? " \(targets.count) Items" : ""
        Button("Paste\(count)") { ctrl.paste(targets) }
        Button("Copy\(count)") { ctrl.copy(targets) }
        Divider()
        Menu("Pin\(count) to") {
            ForEach(state.boards) { board in
                Button(board.name) { ctrl.pin(targets, to: board.id) }
            }
            if !state.boards.isEmpty { Divider() }
            Button("New Pinboard") { ctrl.pinToNewBoard(targets) }
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
            if let icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)) }
            if let dot { Circle().fill(dot).frame(width: 9, height: 9) }
            // ZStack sizes to its widest child (the hidden bold copy), so the
            // visible text can switch weight without changing the cell width.
            ZStack {
                Text(text).font(.system(size: 13.5, weight: .semibold)).hidden()
                Text(text).font(.system(size: 13.5, weight: isCurrent ? .semibold : .medium)).lineLimit(1)
            }
            .fixedSize()
        }
        .foregroundStyle(isCurrent ? .primary : .secondary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isCurrent ? .white.opacity(0.14) : .clear))
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
/// window, and focusing its text field would activate CopyPasta and close the panel.
struct BoardChip: View {
    let board: Board
    let isCurrent: Bool
    let isRenaming: Bool
    unowned let ctrl: PanelController
    @State private var dropTargeted = false

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
        // Drop a card here to pin it: the tab lights up in its color while one hovers.
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(board.color.opacity(dropTargeted ? 0.4 : 0)))
        .scaleEffect(dropTargeted ? 1.08 : 1)
        .animation(.easeOutStrong(dropTargeted ? 0.12 : 0.3), value: dropTargeted)
        .onDrop(of: [.item], delegate: BoardDrop(boardID: board.id, ctrl: ctrl, targeted: $dropTargeted))
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

/// Pins the cards dragged from the panel to the board; ignores drags from other apps.
private struct BoardDrop: DropDelegate {
    let boardID: Int64
    unowned let ctrl: PanelController
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool { ctrl.isDraggingCards }
    func dropEntered(info: DropInfo) { targeted = ctrl.isDraggingCards }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        let pinned = ctrl.drop(onBoard: boardID)
        // Pinned: the tab stays lit a beat, confirming where the card went, then settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + (pinned ? 0.25 : 0)) { targeted = false }
        return pinned
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
            Circle().fill(board.color).frame(width: 9, height: 9)
            PanelTextField(text: $name, placeholder: "Board name", selectsAllOnFocus: true,
                           onSubmit: { ctrl.finishRename(board.id, to: name) },
                           onCancel: { ctrl.finishRename(board.id, to: nil) })
                .frame(width: 140)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.14)))
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
        field.font = .systemFont(ofSize: 14)
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

/// One clip, styled after Paste's cards: a header in the source app's color (the
/// board's, on a pinboard) with the app's icon cropped into its corner, and below it
/// the content, shown the way it looked where it was copied.
struct CardView: View {
    let item: ClipItem
    let selected: Bool
    var boardColor: Color?

    static let width: CGFloat = 236
    static let height: CGFloat = 236
    static let headerHeight: CGFloat = 50
    private static let radius: CGFloat = 13
    private static var bodyHeight: CGFloat { height - headerHeight }

    /// Card body and text colors: fixed, the panel is always dark.
    static let surface = Color(white: 0.16)
    static let ink = NSColor(white: 0.93, alpha: 1)

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(width: Self.width, height: Self.bodyHeight)
                .clipped()
        }
        .background(Self.surface)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .padding(3) // room for the selection ring, hugging the card
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius + 3, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(selected ? 1 : 0) // instant: arrowing through cards must keep up with the keys
        )
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 13.5, weight: .semibold))
            Text(age).font(.system(size: 11)).opacity(0.8)
        }
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, 60) // clear of the icon
        .frame(width: Self.width, height: Self.headerHeight, alignment: .leading)
        .background(boardColor ?? AppLook.color(for: item.sourceBundleID))
        .overlay(alignment: .topTrailing) {
            if let icon = AppLook.icon(for: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .offset(x: 12, y: -8)
                    .shadow(color: .black.opacity(0.18), radius: 3, x: -1, y: 1)
            }
        }
        .clipped()
    }

    // The header shows the *type*; the content lives in the body.
    private var title: String {
        switch item.kind {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return item.filePaths.count > 1 ? "\(item.filePaths.count) Files" : "File"
        }
    }

    private var age: String {
        if Date().timeIntervalSince(item.createdAt) < 60 { return "just now" }
        return Self.relative.localizedString(for: item.createdAt, relativeTo: Date())
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text: textContent
        case .link: linkContent
        case .image: imageContent
        case .file: fileContent
        }
    }

    /// Scrolls with the mouse or trackpad when it's longer than the card.
    private var textContent: some View {
        OverflowScroll {
            Text(CardText.preview(for: item))
                .font(CardText.isCode(item) ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                .lineSpacing(2.5)
                .foregroundStyle(Color(nsColor: Self.ink))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 32, trailing: 12))   // clear of the footer
        }
            .overlay(alignment: .bottom) {
                footer("\(item.charCount.formatted()) \(item.charCount == 1 ? "character" : "characters")")
            }
    }

    /// No network fetch for a preview (fetching can use up one-time login links), so
    /// the card shows the address itself: the site big, the rest of it below.
    private var linkContent: some View {
        let raw = (item.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: raw)
        let host = url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? raw
        let path = raw.replacingOccurrences(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]*/?"#, with: "", options: .regularExpression)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(colors: [linkTint.opacity(0.32), linkTint.opacity(0.1)],
                               startPoint: .top, endPoint: .bottom)
                Text(String(host.prefix(1)).uppercased())
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(colors: [linkTint.opacity(0.85), linkTint],
                                                 startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            }
            .frame(height: 108)
            VStack(alignment: .leading, spacing: 3) {
                Text(host)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Self.ink))
                    .lineLimit(1)
                Text(verbatim: path.isEmpty ? raw : "/" + path)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var linkTint: Color { boardColor ?? AppLook.color(for: item.sourceBundleID) }

    @ViewBuilder
    private var imageContent: some View {
        if let image = Self.thumbImage(for: item) {
            ZStack(alignment: .bottom) {
                if fitsInside {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: max(1, CGFloat(item.pixelW) / 2), maxHeight: max(1, CGFloat(item.pixelH) / 2))
                        .padding(EdgeInsets(top: 14, leading: 14, bottom: 34, trailing: 14))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(white: 0.2))
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: Self.width, height: Self.bodyHeight)
                        .clipped()
                }
                if item.pixelW > 0 {
                    Text(verbatim: "\(item.pixelW) × \(item.pixelH)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(.bottom, 9)
                }
            }
        } else {
            Image(systemName: "photo")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.3))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Small images (icons, small crops) and very long or tall ones are shown whole;
    /// filling the card would blow them up blurry or crop away most of them.
    private var fitsInside: Bool {
        guard item.pixelW > 0, item.pixelH > 0 else { return false }
        let aspect = Double(item.pixelW) / Double(item.pixelH)
        let small = CGFloat(item.pixelW) < Self.width * 2 && CGFloat(item.pixelH) < Self.bodyHeight * 2
        return small || aspect > 2.6 || aspect < 0.4
    }

    private var fileContent: some View {
        let paths = item.filePaths
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let folder = ((paths.first ?? "") as NSString).deletingLastPathComponent
        return VStack(spacing: 8) {
            ZStack {
                // Several files: the next two peek out behind the first, like a stack.
                ForEach(Array(paths.prefix(3).enumerated().reversed()), id: \.offset) { i, path in
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 76, height: 76)
                        .rotationEffect(.degrees(Double(i) * 7))
                        .offset(x: CGFloat(i) * 9, y: CGFloat(i) * -2)
                        .opacity(i == 0 ? 1 : 0.85)
                }
            }
            Text(names.count > 1 ? "\(names[0]) and \(names.count - 1) more" : (names.first ?? ""))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(nsColor: Self.ink))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            footer((folder as NSString).abbreviatingWithTildeInPath)
        }
    }

    /// Centered caption at the bottom; the content above fades out under it.
    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.42))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            .padding(.bottom, 8)
            .background(LinearGradient(stops: [.init(color: Self.surface.opacity(0), location: 0),
                                               .init(color: Self.surface, location: 0.62)],
                                       startPoint: .top, endPoint: .bottom))
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
}

// MARK: - Card text

/// A text card's preview: the copied rich text as it looked in its app (fonts, weights,
/// syntax colors), fitted to the card; otherwise the plain text, tidied.
enum CardText {
    private final class Box { let text: AttributedString; init(_ text: AttributedString) { self.text = text } }
    private static let cache = NSCache<NSString, Box>()

    static func preview(for item: ClipItem) -> AttributedString {
        // Keyed by the hash too: an edit changes the text under the same id.
        let key = "\(item.id):\(item.contentHash)" as NSString
        if let hit = cache.object(forKey: key) { return hit.text }
        let text = item.rtf.flatMap(rich) ?? AttributedString(tidy(item.plainText ?? ""))
        cache.setObject(Box(text), forKey: key)
        return text
    }

    /// Plain text copied from a terminal or code editor shows in a monospaced font,
    /// the way it looked there.
    static func isCode(_ item: ClipItem) -> Bool {
        item.rtf == nil && codeApps.contains(item.sourceBundleID ?? "")
    }

    private static let codeApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4",
        "com.exafunction.windsurf",
    ]

    /// Drops blank lines at both ends and the indentation every line shares (a snippet
    /// copied from the middle of indented code), and caps what a card can show anyway.
    static func tidy(_ text: String) -> String {
        var lines = String(text.prefix(3000))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        let isBlank = { (line: Substring) in line.allSatisfy(\.isWhitespace) }
        while let first = lines.first, isBlank(first) { lines.removeFirst() }
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        let indentOf = { (line: Substring) in line.prefix { $0 == " " || $0 == "\t" }.count }
        let shared = lines.filter { !isBlank($0) }.map(indentOf).min() ?? 0
        return lines.map { String($0.dropFirst(min(shared, indentOf($0)))) }.joined(separator: "\n")
    }

    /// Fonts scaled so the body text reads at card size (headings stay bigger, within
    /// bounds); colors that would vanish on the dark card lightened, keeping their hue.
    private static func rich(_ rtf: Data) -> AttributedString? {
        guard let source = NSAttributedString(rtf: rtf, documentAttributes: nil) else { return nil }
        let string = source.string as NSString
        let skip = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}"))
        var start = 0, end = string.length
        while start < end, let u = Unicode.Scalar(string.character(at: start)), skip.contains(u) { start += 1 }
        while end > start, let u = Unicode.Scalar(string.character(at: end - 1)), skip.contains(u) { end -= 1 }
        guard end > start else { return nil }
        let text = source.attributedSubstring(from: NSRange(location: start, length: min(end - start, 2000)))
        let all = NSRange(location: 0, length: text.length)

        // The most used size is the body size; it maps to the card's 12.5pt.
        var usage: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: all) { value, range, _ in
            usage[(value as? NSFont)?.pointSize ?? 12, default: 0] += range.length
        }
        let bodySize = usage.max { $0.value < $1.value }?.key ?? 12
        var monospaced = false
        text.enumerateAttribute(.font, in: all) { value, _, stop in
            if (value as? NSFont)?.isFixedPitch == true { monospaced = true; stop.pointee = true }
        }
        let scale = (monospaced ? 11.5 : 12.5) / max(bodySize, 1)

        var out = AttributedString()
        text.enumerateAttributes(in: all) { attrs, range, _ in
            let piece = (text.string as NSString).substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !piece.isEmpty else { return }
            var run = AttributedString(piece)
            let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: bodySize)
            let size = min(max(font.pointSize * scale, 10), 19)
            run.font = Font(NSFont(descriptor: font.fontDescriptor, size: size) ?? .systemFont(ofSize: size))
            run.foregroundColor = Color(nsColor: readable(attrs[.foregroundColor] as? NSColor))
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 { run.underlineStyle = .single }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { run.strikethroughStyle = .single }
            out += run
        }
        return out.characters.isEmpty ? nil : out
    }

    /// Light colors stay. Dark ones (black text, a light theme's syntax colors) would
    /// vanish on the dark card: grays become the card's text color, hues get lightened.
    static func readable(_ color: NSColor?) -> NSColor {
        guard let c = color?.usingColorSpace(.sRGB) else { return CardView.ink }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        if luminance >= 0.45 { return c }
        if c.saturationComponent < 0.2 { return CardView.ink }
        return NSColor(hue: c.hueComponent, saturation: min(c.saturationComponent, 0.6),
                       brightness: max(c.brightnessComponent, 0.97), alpha: 1)
    }
}

// MARK: - App look

/// The source app's icon, and the color its cards' header takes from it (like Paste:
/// Messages green, Mail blue, Notes yellow).
enum AppLook {
    private static var icons: [String: NSImage] = [:]
    private static var colors: [String: Color] = [:]
    /// Header for unknown apps and black, white or gray icons.
    static let neutral = Color(white: 0.3)

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    static func color(for bundleID: String?) -> Color {
        guard let bundleID else { return neutral }
        if let cached = colors[bundleID] { return cached }
        let color = icon(for: bundleID).flatMap(dominantColor).map { Color(nsColor: $0) } ?? neutral
        colors[bundleID] = color
        return color
    }

    /// The icon's most common vivid hue, averaged, toned so white text stays readable
    /// on it; nil for an icon with little color.
    static func dominantColor(_ icon: NSImage) -> NSColor? {
        let side = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        // 12 hue buckets, each pixel weighted by how vivid it is.
        var weight = [CGFloat](repeating: 0, count: 12)
        var sum = [(r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0), count: 12)
        var opaque = 0
        for x in 0..<side {
            for y in 0..<side {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.6 else { continue }
                opaque += 1
                guard c.saturationComponent > 0.35, c.brightnessComponent > 0.3 else { continue }
                let w = c.saturationComponent * c.brightnessComponent
                let i = Int((c.hueComponent * 12).rounded()) % 12
                weight[i] += w
                sum[i].r += c.redComponent * w
                sum[i].g += c.greenComponent * w
                sum[i].b += c.blueComponent * w
            }
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              opaque > 0, weight[best] > CGFloat(opaque) * 0.03 else { return nil }
        let w = weight[best]
        let average = NSColor(srgbRed: sum[best].r / w, green: sum[best].g / w, blue: sum[best].b / w, alpha: 1)
        return NSColor(hue: average.hueComponent, saturation: max(average.saturationComponent, 0.72),
                       brightness: min(max(average.brightnessComponent, 0.7), 0.9), alpha: 1)
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
