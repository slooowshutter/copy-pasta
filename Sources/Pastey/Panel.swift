import AppKit
import SwiftUI

final class DrawerState: ObservableObject {
    @Published var query = "" { didSet { refilter() } }
    @Published var items: [ClipItem] = []
    @Published var selection = 0           // the cursor (where shift extends from moves)
    @Published var selectedIndices: Set<Int> = [0]
    @Published var shownTick = 0
    @Published var boards: [Board] = []
    @Published var currentBoardID: Int64?
    @Published var searchOpen = false

    private var all: [ClipItem] = []
    private var anchor = 0                  // fixed end of a shift-extended range

    var currentBoard: Board? {
        boards.first { $0.id == currentBoardID }
    }

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

    func reload() {
        boards = DB.shared.boards()
        if currentBoardID != nil, currentBoard == nil { currentBoardID = nil }
        all = DB.shared.recent(boardID: currentBoardID)
        refilter()
    }

    private func refilter() {
        if query.isEmpty {
            items = all
        } else {
            items = all.filter {
                ($0.plainText?.localizedCaseInsensitiveContains(query) ?? false)
                    || ($0.sourceAppName?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        selectSingle(0)
    }
}

/// Borderless panel that can take keyboard input without activating our app —
/// the frontmost app stays frontmost, which is what makes "paste back" possible later.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PanelController: NSObject, NSWindowDelegate {
    let state = DrawerState()

    private var panel: Panel!
    private var keyMonitor: Any?
    private var lastToggle = Date.distantPast

    override init() {
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

    /// Arrows/enter/esc drive the cards; everything else falls through to the search field.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
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
        case 36: // return — copy the whole selection
            commitSelection()
            return nil
        case 51 where cmd: // cmd+delete — delete the whole selection
            deleteSelection()
            return nil
        default:
            return event
        }
    }

    // MARK: - Actions (also called from DrawerView)

    /// Copy a single item (double-click / tap-then-Enter on one card).
    func commit(_ item: ClipItem) {
        DB.shared.copyToPasteboard(item)
        hide()
    }

    /// Copy the whole selection. One item keeps its rich/image/file flavors; a
    /// multi-select is flattened to text joined by blank lines (Paste does the same).
    func commitSelection() {
        let items = state.selectedItems
        guard !items.isEmpty else { return }
        if items.count == 1 {
            DB.shared.copyToPasteboard(items[0])
        } else {
            let text = items.compactMap(Self.textRepresentation).joined(separator: "\n\n")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        hide()
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
        state.reload()
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
    }

    func renameBoard(_ id: Int64, to name: String) {
        DB.shared.renameBoard(id, to: name)
        state.reload()
    }

    func recolorBoard(_ id: Int64, to hex: String) {
        DB.shared.recolorBoard(id, to: hex)
        state.reload()
    }

    func deleteBoard(_ id: Int64) {
        DB.shared.deleteBoard(id)
        if state.currentBoardID == id {
            activateBoard(nil)
        } else {
            state.reload()
        }
    }

    func pin(_ item: ClipItem, to boardID: Int64) {
        DB.shared.pin(item, to: boardID)
        if state.currentBoardID == boardID { state.reload() }
    }

    func pinToNewBoard(_ item: ClipItem) {
        let color = Board.presetColors[state.boards.count % Board.presetColors.count]
        let board = DB.shared.createBoard(name: "Untitled", colorHex: color)
        DB.shared.pin(item, to: board.id)
        state.reload()
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
        state.reload()
        state.selectSingle(min(index, state.lastIndex))
    }
}
