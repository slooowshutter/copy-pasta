import AppKit
import SwiftUI

final class DrawerState: ObservableObject {
    static let pageSize = 200

    @Published var query = "" { didSet { if query != oldValue { reload() } } }
    @Published var items: [ClipItem] = []
    @Published var selection = 0           // the cursor (where shift extends from moves)
    @Published var selectedIndices: Set<Int> = [0]
    @Published var shownTick = 0
    @Published var boards: [Board] = []
    @Published var currentBoardID: Int64?
    @Published var searchOpen = false
    @Published var isPaused = false
    @Published var editingItem: ClipItem?     // non-nil while the text editor is open
    @Published var editText = ""
    @Published var renamingBoardID: Int64?    // board chip showing its inline name field

    private var anchor = 0                  // fixed end of a shift-extended range
    private var hasMore = false             // more rows past the loaded pages

    var currentBoard: Board? {
        boards.first { $0.id == currentBoardID }
    }

    /// A board's inline name field is on screen. (Search replaces the board chips, so
    /// while it's open there's no field, whatever renamingBoardID says.)
    var isRenaming: Bool { renamingBoardID != nil && !searchOpen }

    var lastIndex: Int { max(0, items.count - 1) }

    /// Items in the current selection, in display order.
    var selectedItems: [ClipItem] {
        selectedIndices.sorted().compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    /// Move the cursor and collapse to a single selection.
    func selectSingle(_ index: Int) {
        selection = index
        anchor = index
        selectedIndices = items.isEmpty ? [] : [index]
    }

    /// Move the cursor and extend the selection to cover anchor…index.
    func extend(to index: Int) {
        selection = index
        selectedIndices = Set(min(anchor, index)...max(anchor, index))
    }

    /// Re-query the current board + search. `keepPosition` (refreshes while the user
    /// is mid-scroll) keeps the pages already loaded and the selected item; otherwise
    /// start over at the top.
    func reload(keepPosition: Bool = false) {
        boards = DB.shared.boards()
        if currentBoardID != nil, currentBoard == nil { currentBoardID = nil }
        let selectedID = keepPosition && items.indices.contains(selection) ? items[selection].id : nil
        let limit = keepPosition ? max(Self.pageSize, items.count) : Self.pageSize
        items = DB.shared.recent(boardID: currentBoardID, matching: query, limit: limit)
        hasMore = items.count == limit
        selectSingle(selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0)
    }

    /// Next page, as scrolling or arrowing nears the end of what's loaded.
    func loadMore() {
        guard hasMore else { return }
        let page = DB.shared.recent(boardID: currentBoardID, matching: query, limit: Self.pageSize, offset: items.count)
        items += page
        hasMore = page.count == Self.pageSize
    }
}

/// Borderless panel that can take keyboard input without activating our app —
/// the frontmost app stays frontmost, which is what makes "paste back" possible later.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PanelController: NSObject, NSWindowDelegate {
    let state = DrawerState()

    private let watcher: ClipboardWatcher
    private var panel: Panel!
    private var keyMonitor: Any?
    private var lastToggle = Date.distantPast
    private var lastClick: (id: Int64, at: Date, location: NSPoint)?
    private var askedForAccessibility = false

    init(watcher: ClipboardWatcher) {
        self.watcher = watcher
        super.init()
        panel = Panel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        panel.contentView = NSHostingView(rootView: DrawerView(state: state, ctrl: self))
    }

    var isVisible: Bool { panel.isVisible }

    /// Debounced so a single shortcut press that fires more than once (or a
    /// stray repeat) can't show-then-immediately-hide, or land on "open" by luck.
    func toggle() {
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.25 else { return }
        lastToggle = now
        isVisible ? hide() : show()
    }

    func show() {
        guard !isVisible else { return }
        state.query = ""
        state.searchOpen = false
        state.editingItem = nil
        state.renamingBoardID = nil
        state.reload()
        state.shownTick += 1

        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        plog("show (front=\(front))")

        // Anchor to the screen the user is working on (the one with keyboard
        // focus) — not the mouse, which drifts and made the panel jump around.
        // Always pin to the bottom of that screen's usable area (above the Dock).
        guard let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let frame = NSRect(x: vf.minX + 8, y: vf.minY + 8, width: vf.width - 16, height: 352)

        addKeyMonitor()
        panel.setFrame(frame.offsetBy(dx: 0, dy: -30), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        removeKeyMonitor()
        state.editingItem = nil     // discard any in-progress edit
        state.renamingBoardID = nil // …or board rename
        panel.orderOut(nil)
    }

    private func addKeyMonitor() {
        removeKeyMonitor() // never stack two monitors
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    /// Arrows/enter/esc drive the cards; typing goes to search (opening it if needed);
    /// everything else falls through.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if state.isRenaming { return event }   // the board name field gets every key
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let searchHasFocus = panel.firstResponder is NSText  // the search field's editor
        switch event.keyCode {
        case 53: // esc — close search first if open, else dismiss the panel
            if state.searchOpen {
                state.searchOpen = false
                state.query = ""
            } else {
                hide()
            }
            return nil
        case 123 where cmd: // cmd+left — previous board
            cycleBoard(-1)
            return nil
        case 124 where cmd: // cmd+right — next board
            cycleBoard(1)
            return nil
        case 123 where shift: // shift+left — extend selection
            state.extend(to: max(0, state.selection - 1))
            return nil
        case 124 where shift: // shift+right — extend selection
            state.extend(to: min(state.lastIndex, state.selection + 1))
            return nil
        case 123: // left
            state.selectSingle(max(0, state.selection - 1))
            return nil
        case 124: // right
            state.selectSingle(min(state.lastIndex, state.selection + 1))
            return nil
        case 36: // return — paste the whole selection
            commitSelection()
            return nil
        case 51 where cmd && !state.searchOpen: // cmd+delete — delete the selection (in search: edits the query)
            deleteSelection()
            return nil
        case 14 where cmd: // cmd+E — edit the selected item's text
            beginEditing()
            return nil
        case 3 where cmd: // cmd+F — search (already open: take focus back)
            state.searchOpen = true
            searchField()?.takeFocus()
            return nil
        default:
            if searchHasFocus { return event }
            // Search is open but its field lost focus (e.g. to the ⌘E editor): give it
            // focus back before this key is dispatched, so the key lands in the field.
            if let field = searchField() {
                field.takeFocus()
                return event
            }
            return typeToSearch(event) ? nil : event
        }
    }

    /// The search field, if search is open. It's then the panel's only AutoFocusTextField
    /// (search replaces the board chips, and with them any name field).
    private func searchField() -> AutoFocusTextField? {
        guard state.searchOpen, let root = panel.contentView else { return nil }
        return Self.firstTextField(in: root)
    }

    private static func firstTextField(in view: NSView) -> AutoFocusTextField? {
        if let field = view as? AutoFocusTextField { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }

    /// A printable keystroke while the search field doesn't have focus opens search
    /// with it as the query. The field then takes focus (caret after the text), and
    /// later keystrokes go straight to it.
    private func typeToSearch(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control]),
              let chars = event.characters, !chars.isEmpty,
              !(chars == " " && state.query.isEmpty),
              chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) })
        else { return false }
        state.searchOpen = true
        state.query += chars
        return true
    }

    // MARK: - Actions (also called from DrawerView)

    /// Card clicks: shift extends the selection, a double-click pastes. One tap gesture
    /// plus our own double-click check, because SwiftUI's double+single tap pair holds
    /// every single click back for the double-click interval. The second click is matched
    /// by screen position, not by the card under it: the first click scrolls its card to
    /// the center, so by then a neighbouring card may have slid under the pointer.
    func cardClicked(at index: Int) {
        guard state.items.indices.contains(index) else { return }
        let now = Date()
        let location = NSEvent.mouseLocation
        if let last = lastClick, now.timeIntervalSince(last.at) < NSEvent.doubleClickInterval,
           abs(location.x - last.location.x) <= 4, abs(location.y - last.location.y) <= 4 {
            lastClick = nil
            if let item = state.items.first(where: { $0.id == last.id }) { paste([item]) }
            return
        }
        lastClick = (state.items[index].id, now, location)
        if NSEvent.modifierFlags.contains(.shift) {
            state.extend(to: index)
        } else {
            state.selectSingle(index)
        }
    }

    /// Enter: paste the whole selection.
    func commitSelection() {
        paste(state.selectedItems)
    }

    /// Put items on the pasteboard, close, and paste into the app the user was in.
    func paste(_ items: [ClipItem]) {
        deliver(items, andPaste: true)
    }

    /// Pasteboard only (context menu "Copy").
    func copy(_ item: ClipItem) {
        deliver([item], andPaste: false)
    }

    /// One item keeps its rich/image/file flavors; a multi-select is flattened to
    /// text joined by blank lines (Paste does the same).
    private func deliver(_ items: [ClipItem], andPaste: Bool) {
        guard !items.isEmpty else { return }
        if items.count == 1 {
            DB.shared.copyToPasteboard(items[0])
            if !watcher.isPaused { DB.shared.bumpToHistory(items[0]) }
        } else {
            let text = items.compactMap(Self.textRepresentation).joined(separator: "\n\n")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        watcher.skipCurrentChange() // not a new copy: no combined-text junk item, no re-crediting the frontmost app
        hide()
        if andPaste { pasteIntoFrontApp() }
    }

    /// The panel never activates Pastey, so the user's app is still frontmost and gets
    /// the ⌘V once the panel is gone. Without Accessibility permission the item is still
    /// on the clipboard: ask once per launch, then quietly fall back to copy-only.
    private func pasteIntoFrontApp() {
        guard AppSettings.shared.pasteDirectly, !NSApp.isActive else { return }
        guard Paster.isTrusted else {
            if !askedForAccessibility {
                askedForAccessibility = true
                Paster.requestAccess()
            }
            return
        }
        // A beat for the panel to order out so keyboard focus is back in that app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Paster.pasteIntoFrontApp() }
    }

    private static func textRepresentation(_ item: ClipItem) -> String? {
        if let t = item.plainText, !t.isEmpty { return t }
        return item.filePaths.isEmpty ? nil : item.filePaths.joined(separator: "\n")
    }

    func deleteSelection() {
        let items = state.selectedItems
        guard !items.isEmpty else { return }
        let firstIndex = state.selectedIndices.min() ?? 0
        items.forEach { DB.shared.delete($0) }
        state.reload(keepPosition: true)
        state.selectSingle(min(firstIndex, state.lastIndex))
    }

    func activateBoard(_ id: Int64?) {
        state.query = ""
        state.currentBoardID = id
        state.reload()
    }

    private func cycleBoard(_ delta: Int) {
        let ids: [Int64?] = [nil] + state.boards.map { $0.id }
        let current = ids.firstIndex(of: state.currentBoardID) ?? 0
        let next = (current + delta + ids.count) % ids.count
        activateBoard(ids[next])
    }

    func createBoard() {
        let color = Board.presetColors[state.boards.count % Board.presetColors.count]
        let board = DB.shared.createBoard(name: "Untitled", colorHex: color)
        activateBoard(board.id)
        state.renamingBoardID = board.id    // name it right away
    }

    func beginRename(_ id: Int64) {
        state.renamingBoardID = id
    }

    /// From the inline name field: Return/click-away commits, Esc passes nil. Ignores
    /// a stale call — the field also reports end-of-editing as it's torn down.
    func finishRename(_ id: Int64, to name: String?) {
        guard state.renamingBoardID == id else { return }
        state.renamingBoardID = nil
        guard let name else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        renameBoard(id, to: trimmed.isEmpty ? "Untitled" : trimmed)
    }

    func renameBoard(_ id: Int64, to name: String) {
        DB.shared.renameBoard(id, to: name)
        state.reload(keepPosition: true)
    }

    func recolorBoard(_ id: Int64, to hex: String) {
        DB.shared.recolorBoard(id, to: hex)
        state.reload(keepPosition: true)
    }

    func deleteBoard(_ id: Int64) {
        DB.shared.deleteBoard(id)
        if state.renamingBoardID == id { state.renamingBoardID = nil }
        if state.currentBoardID == id {
            activateBoard(nil)
        } else {
            state.reload(keepPosition: true)
        }
    }

    func pin(_ item: ClipItem, to boardID: Int64) {
        DB.shared.pin(item, to: boardID)
        if state.currentBoardID == boardID { state.reload(keepPosition: true) }
    }

    func pinToNewBoard(_ item: ClipItem) {
        let color = Board.presetColors[state.boards.count % Board.presetColors.count]
        let board = DB.shared.createBoard(name: "Untitled", colorHex: color)
        DB.shared.pin(item, to: board.id)
        state.reload(keepPosition: true)
        if !state.searchOpen { state.renamingBoardID = board.id }   // search hides the chips
    }

    /// Dev-only: render our own drawer to a PNG so the build loop can "see" it
    /// without Screen Recording permission. Vibrancy won't render; layout will.
    func snapshot() {
        if !isVisible { show() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard let view = panel.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/pastey-panel.png"))
        }
    }

    func deleteItem(_ item: ClipItem) {
        let index = state.items.firstIndex(of: item) ?? state.selection
        DB.shared.delete(item)
        state.reload(keepPosition: true)
        state.selectSingle(min(index, state.lastIndex))
    }

    // MARK: - Ellipsis menu (routed to AppDelegate, which owns watcher/status/window)

    func openSettings() {
        (NSApp.delegate as? AppDelegate)?.openSettings()
        hide()
    }

    func pause(for interval: TimeInterval) {
        (NSApp.delegate as? AppDelegate)?.pause(for: interval)
        hide()
    }

    func togglePause() {
        (NSApp.delegate as? AppDelegate)?.togglePause()
    }

    // MARK: - Inline text editing (⌘E)

    /// Open the plain-text editor for the selected text/link item. Suspends the
    /// card-nav key monitor so typing (arrows, return, esc) reaches the editor.
    func beginEditing() {
        guard state.items.indices.contains(state.selection) else { return }
        let item = state.items[state.selection]
        guard item.kind == .text || item.kind == .link, let text = item.plainText else {
            NSSound.beep()   // images/files have no editable text
            return
        }
        state.editText = text
        state.editingItem = item
        removeKeyMonitor()
    }

    func saveEdit() {
        guard let item = state.editingItem else { return }
        DB.shared.updateText(item, to: state.editText)
        endEditing()
        state.reload(keepPosition: true)    // keeps the edited card selected
    }

    func cancelEdit() {
        endEditing()
    }

    private func endEditing() {
        state.editingItem = nil
        if isVisible { addKeyMonitor() }     // restore card navigation
    }
}
