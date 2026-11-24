import AppKit
import AVFoundation
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
    /// The Recordings tab is open (then the cards are `recordings`, not `items`).
    @Published var showingRecordings = false
    @Published var recordings: [RecordingCard] = []
    /// The recording whose audio is playing (PanelController.playback: where it's at).
    @Published var playingID: UUID?
    /// Every recording, unfiltered: refreshed as the panel opens and as dictation moves on.
    @Published var allRecordings: [RecordingCard] = [] { didSet { if showingRecordings { reload(keepPosition: true) } } }

    private var anchor = 0                  // fixed end of a shift-extended range
    private var hasMore = false             // more rows past the loaded pages

    var currentBoard: Board? {
        boards.first { $0.id == currentBoardID }
    }

    /// A board's inline name field is on screen. (Search replaces the board chips, so
    /// while it's open there's no field, whatever renamingBoardID says.)
    var isRenaming: Bool { renamingBoardID != nil && !searchOpen }

    /// Cards in the open tab.
    var count: Int { showingRecordings ? recordings.count : items.count }
    var lastIndex: Int { max(0, count - 1) }

    var selectedRecording: RecordingCard? {
        showingRecordings && recordings.indices.contains(selection) ? recordings[selection] : nil
    }

    /// Items in the current selection, in display order.
    var selectedItems: [ClipItem] {
        selectedIndices.sorted().compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    /// Move the cursor and collapse to a single selection.
    func selectSingle(_ index: Int) {
        selection = index
        anchor = index
        selectedIndices = count == 0 ? [] : [index]
    }

    /// Move the cursor and extend the selection to cover anchor…index.
    func extend(to index: Int) {
        if showingRecordings { return selectSingle(index) }   // one recording at a time
        selection = index
        selectedIndices = Set(min(anchor, index)...max(anchor, index))
    }

    /// Re-query the current board + search. `keepPosition` (refreshes while the user
    /// is mid-scroll) keeps the pages already loaded and the selected item; otherwise
    /// start over at the top.
    func reload(keepPosition: Bool = false) {
        boards = DB.shared.boards()
        if showingRecordings {
            let selectedID = keepPosition ? selectedRecording?.id : nil
            recordings = query.isEmpty ? allRecordings
                : allRecordings.filter { $0.text?.localizedCaseInsensitiveContains(query) == true }
            selectSingle(selectedID.flatMap { id in recordings.firstIndex { $0.id == id } } ?? 0)
            return
        }
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

    /// Fits one row of cards, plus the gap under the drawer (panelInset). The window spans
    /// the screen's full width at its very bottom; the drawer floats inside it.
    private static let height: CGFloat = 336 + panelInset

    private let watcher: ClipboardWatcher
    private var panel: Panel!
    private var keyMonitor: Any?
    private var lastToggle = Date.distantPast
    private var lastClick: (id: Int64, at: Date, location: NSPoint)?
    /// The ••• menu is open (set around its popUp): it takes the key focus while it's up,
    /// which must not count as clicking away. (Not from NSMenu's tracking notifications:
    /// those come for every menu in the app, and a missed "ended" left the panel stuck open.)
    private var menuOpen = false
    private var lastRecordingClick: (id: UUID, at: Date)?
    let playback = Playback()
    private var player: AVPlayer?
    private var playerEnd: NSObjectProtocol?
    private var playerClock: Any?
    private var askedForAccessibility = false
    /// Open as far as the user is concerned; the panel may still be sliding out after hide().
    private var shown = false
    // The slide's spring (see slide(toY:response:)).
    private var slideTarget: CGFloat = 0
    private var slideVelocity: CGFloat = 0     // points per second
    private var slideResponse: CGFloat = 0.25
    private var slideLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    private weak var slideScreen: NSScreen?
    /// The drawer's view. It slides inside the panel, which stays put on its screen and
    /// clips it: sliding the whole window from below the screen showed it on whatever
    /// display sits below (a MacBook under two external monitors).
    private var host: NSView!
    /// Closing: orders the panel out and runs hide()'s completion.
    private var afterHide: (() -> Void)?
    /// Cards being dragged, for a drop on a pinboard tab (see drop(onBoard:)).
    private var dragged: [ClipItem] = []

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

        let host = FirstClickHostingView(rootView: DrawerView(state: state, ctrl: self))
        // The panel's frame is set in show(). By default the hosting view also sizes the
        // window to its SwiftUI content, which shrank it from the top edge down and left
        // the panel floating above the bottom of the screen.
        host.sizingOptions = []
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        host.autoresizingMask = [.width]
        clip.addSubview(host)
        panel.contentView = clip
        self.host = host
    }

    var isVisible: Bool { shown }

    /// Debounced so a single shortcut press that fires more than once (or a
    /// stray repeat) can't show-then-immediately-hide, or land on "open" by luck.
    func toggle() {
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.25 else { return }
        lastToggle = now
        isVisible ? hide() : show()
    }

    func show() {
        guard !shown else { return }
        // The screen the user is working on (the one with keyboard focus), not the
        // mouse's, which drifts. Its full frame, not visibleFrame: like Paste, the panel
        // sits at the very bottom, over the Dock, whether the Dock is showing or not.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        shown = true
        dragged = []
        state.query = ""
        state.searchOpen = false
        state.editingItem = nil
        state.renamingBoardID = nil
        state.reload()
        refreshRecordings()
        state.shownTick += 1

        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        plog("show (front=\(front))")

        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                           width: screen.frame.width, height: Self.height)
        addKeyMonitor()
        afterHide = nil
        slideScreen = screen
        // Rise from the screen's bottom edge. Reopened while still sliding out on this
        // screen: turn around from where it is, at the speed it's going.
        if !panel.isVisible || panel.frame != frame {
            panel.setFrame(frame, display: false)
            host.frame = NSRect(x: 0, y: -frame.height, width: frame.width, height: frame.height)
            slideVelocity = 0
        }
        panel.hasShadow = false // a window shadow doesn't follow a view sliding inside it
        panel.makeKeyAndOrderFront(nil)
        slide(toY: 0, response: 0.24)
    }

    /// Slide the panel back down off the screen, the way it came. `then` runs once it's
    /// gone (keyboard focus is back in the user's app by then), unless it was reopened.
    func hide(then completion: (() -> Void)? = nil) {
        guard shown else { return }
        shown = false
        dragged = []
        stopPlayback()
        removeKeyMonitor()
        state.editingItem = nil     // discard any in-progress edit
        state.renamingBoardID = nil // …or board rename
        afterHide = { [weak self] in
            self?.panel.orderOut(nil)
            completion?()
        }
        panel.hasShadow = false
        slide(toY: -panel.frame.height, response: 0.2)
    }

    /// Moves the drawer (inside the panel) to `y` on a critically damped spring (no bounce), one step per
    /// display frame, so it's as smooth as the screen's refresh rate. `response` is
    /// about how long the move takes, in seconds. A new slide starts from where the
    /// panel is and how fast it's moving, so closing or reopening mid-slide turns
    /// around without a jump, the way Apple's sheets move. Reduce Motion: no slide.
    private func slide(toY y: CGFloat, response: CGFloat) {
        slideTarget = y
        slideResponse = response
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            host.setFrameOrigin(NSPoint(x: 0, y: y))
            settle()
            return
        }
        guard slideLink == nil, let screen = slideScreen ?? NSScreen.main else { return } // running: it picks up the new target
        lastFrameTime = nil
        // Stepped in time with the panel's screen.
        let link = screen.displayLink(target: self, selector: #selector(stepSlide(_:)))
        link.add(to: .main, forMode: .common)
        slideLink = link
    }

    @objc private func stepSlide(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = min(now - (lastFrameTime ?? now - 1.0 / 120), 1.0 / 30) // after a hitch, don't leap
        lastFrameTime = now
        let omega = 2 * .pi / slideResponse
        var y = host.frame.minY
        var t: CFTimeInterval = 0
        while t < dt { // small fixed substeps keep the stiff spring stable
            let h = min(1.0 / 600, dt - t)
            slideVelocity += (-omega * omega * (y - slideTarget) - 2 * omega * slideVelocity) * h
            y += slideVelocity * h
            t += h
        }
        let settled = abs(y - slideTarget) < 0.5 && abs(slideVelocity) < 20
        host.setFrameOrigin(NSPoint(x: 0, y: settled ? slideTarget : y))
        if settled || (!shown && host.frame.maxY <= 0) { settle() }
    }

    /// The slide is over: stop stepping. If it was closing, the panel is out of sight:
    /// order it out and run what was waiting on that.
    private func settle() {
        slideLink?.invalidate()
        slideLink = nil
        slideVelocity = 0
        if shown {
            panel.hasShadow = true
            panel.invalidateShadow()
        }
        guard !shown, let afterHide else { return }
        self.afterHide = nil
        afterHide()
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

    /// Clicking away closes the panel. Checked a turn later, when the ••• menu's own
    /// flag is already set if that's what took the focus.
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.menuOpen, !self.panel.isKeyWindow else { return }
            self.hide()
        }
    }

    /// Arrows/enter/esc drive the cards; typing goes to search (opening it if needed);
    /// everything else falls through.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if state.isRenaming { return event }   // the board name field gets every key
        if state.showingRecordings, handleRecordingKey(event) { return nil }
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
        case 8 where cmd: // cmd+C — copy the whole selection (in search: the field's selected text, if any)
            if searchHasFocus, let editor = panel.firstResponder as? NSText, editor.selectedRange.length > 0 {
                return event
            }
            deliver(state.selectedItems, andPaste: false)
            return nil
        case 45 where cmd: // cmd+N — new text item
            newTextItem()
            return nil
        case 43 where cmd: // cmd+, — Settings
            openSettings()
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

    /// Pasteboard only (⌘C, context menu "Copy").
    func copy(_ items: [ClipItem]) {
        deliver(items, andPaste: false)
    }

    /// What a right-click acts on: the whole selection if the card is part of it
    /// (like Finder), otherwise just that card.
    func targets(forCardAt index: Int) -> [ClipItem] {
        guard state.items.indices.contains(index) else { return [] }
        return state.selectedIndices.contains(index) ? state.selectedItems : [state.items[index]]
    }

    /// One item keeps its rich/image/file flavors. Several: texts joined into one,
    /// images and files as files alongside (see DB.copyToPasteboard(_:)).
    private func deliver(_ items: [ClipItem], andPaste: Bool) {
        guard !items.isEmpty else { return }
        if items.count == 1 {
            DB.shared.copyToPasteboard(items[0])
            if !watcher.isPaused { DB.shared.bumpToHistory(items[0]) }
        } else {
            DB.shared.copyToPasteboard(items)
        }
        watcher.skipCurrentChange() // not a new copy: no combined-text junk item, no re-crediting the frontmost app
        // ⌘V only once the panel is gone: until then it has keyboard focus.
        hide { [weak self] in if andPaste { self?.pasteIntoFrontApp() } }
    }

    /// The panel never activates CopyPasta, so the user's app is still frontmost and gets
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
        // A beat for keyboard focus to settle back in that app after the panel ordered out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Paster.pasteIntoFrontApp() }
    }

    func deleteSelection() {
        let items = state.selectedItems
        guard !items.isEmpty else { return }
        let firstIndex = state.selectedIndices.min() ?? 0
        items.forEach { DB.shared.delete($0) }
        // The cards after the gap slide over to close it, rather than jumping.
        withAnimation(.easeOutStrong()) {
            state.reload(keepPosition: true)
            state.selectSingle(min(firstIndex, state.lastIndex))
        }
    }

    func activateBoard(_ id: Int64?) {
        state.query = ""
        state.showingRecordings = false
        state.currentBoardID = id
        state.reload()
    }

    /// ⌘← ⌘→ go round Clipboard, the pinboards, then Recordings (the last tab).
    private func cycleBoard(_ delta: Int) {
        let ids: [Int64?] = [nil] + state.boards.map { $0.id }
        let current = state.showingRecordings ? ids.count : ids.firstIndex(of: state.currentBoardID) ?? 0
        let next = (current + delta + ids.count + 1) % (ids.count + 1)
        if next == ids.count { showRecordings() } else { activateBoard(ids[next]) }
    }

    // MARK: - Recordings tab

    func showRecordings() {
        state.query = ""
        state.currentBoardID = nil
        state.showingRecordings = true
        state.reload()
        refreshRecordings()
    }

    /// Reads the recordings again (as the panel opens, and as dictation starts, stops or
    /// finishes while it's open); the badge on the tab counts from them too.
    func refreshRecordings() {
        Task { @MainActor [weak self] in
            guard let self, let dictation = (NSApp.delegate as? AppDelegate)?.dictation else { return }
            // The live, unsent and failed ones at once, with the history already on screen;
            // then the history, which takes a moment when a new transcript was just added.
            let shown = self.state.allRecordings.filter(\.archived)
            withAnimation(.easeOutStrong()) {
                self.state.allRecordings = (dictation.pendingRecordingCards() + shown).sorted { $0.createdAt > $1.createdAt }
            }
            let archived = await dictation.archivedRecordingCards()
            let pending = dictation.pendingRecordingCards()
            let pendingIDs = Set(pending.map(\.id))   // one finishing right now can be in both
            withAnimation(.easeOutStrong()) {
                self.state.allRecordings = (pending + archived.filter { !pendingIDs.contains($0.id) })
                    .sorted { $0.createdAt > $1.createdAt }
            }
        }
    }

    /// ⏎ pastes a transcript, or does a failed card's main thing (Retry, Add Key…);
    /// ⌘C copy, ⌘D or ⌘E duplicate, ⌘R retry, ⌘⌫ trash.
    /// Every key it takes is handled here, card or no card: none may fall through to the
    /// Clipboard's handling, whose selection indexes a different list.
    private func handleRecordingKey(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        let space = event.keyCode == 49 && !cmd && state.query.isEmpty && !(panel.firstResponder is NSText)
        let ours = event.keyCode == 36 || space || (cmd && [8, 2, 14, 15].contains(event.keyCode))
            || (cmd && event.keyCode == 51 && !state.searchOpen)
        guard ours else { return false }
        if event.keyCode == 8, let editor = panel.firstResponder as? NSText, editor.selectedRange.length > 0 {
            return false   // ⌘C in the search field copies its selected text
        }
        guard let card = state.selectedRecording else { NSSound.beep(); return true }
        switch event.keyCode {
        case 36:
            if card.status == .transcribed { deliverText(card.text, andPaste: true) }
            else if let primary = card.primary { perform(primary.action, on: card) }
            else { NSSound.beep() }
        case 49: card.audioBytes > 0 ? perform(.play, on: card) : NSSound.beep()
        case 8: perform(.copy, on: card)
        case 2, 14: perform(.duplicate, on: card)
        case 15:
            if card.audioBytes > 0, card.needsAttention { perform(.retry, on: card) } else { NSSound.beep() }
        default: perform(.trash, on: card)   // ⌘⌫
        }
        return true
    }

    func perform(_ action: RecordingAction, on card: RecordingCard) {
        MainActor.assumeIsolated {
            guard let app = NSApp.delegate as? AppDelegate else { return }
            switch action {
            case .copy, .copyDraft:
                deliverText(card.text, andPaste: false)
            case .duplicate:
                // A copy you can edit, in Clipboard; the recording stays as it was.
                guard let text = card.text else { return NSSound.beep() }
                activateBoard(nil)
                newTextItem()
                state.editText = text
            case .retry, .send:
                // In the card, panel open: it shows the progress, then the transcript to paste.
                if !app.dictation.retryInPanel(card.id) { NSSound.beep() }
                refreshRecordings()
            case .addKey:
                app.openSettings(pane: "API Keys")
                hide()
            case .play:
                togglePlayback(app.dictation.audioFiles(for: card), id: card.id)
            case .reveal:
                hide()
                app.dictation.revealRecording(card)
            case .trash:
                guard card.status != .recording, card.status != .transcribing else { return NSSound.beep() }
                app.dictation.trashRecording(card)
                refreshRecordings()
            }
        }
    }

    func recordingClicked(at index: Int) {
        guard state.recordings.indices.contains(index) else { return }
        let id = state.recordings[index].id
        let now = Date()
        if let last = lastRecordingClick, last.id == id, now.timeIntervalSince(last.at) < NSEvent.doubleClickInterval {
            lastRecordingClick = nil
            if state.recordings[index].status == .transcribed { deliverText(state.recordings[index].text, andPaste: true) }
            return
        }
        lastRecordingClick = (id, now)
        state.selectSingle(index)
    }

    /// Plays the recording; again (or another card's Play, or closing the panel) stops it.
    /// Its parts go end to end in one timeline, so the bar can jump anywhere in it.
    private func togglePlayback(_ files: [URL], id: UUID) {
        let wasPlaying = state.playingID
        stopPlayback()
        guard wasPlaying != id else { return }
        guard !files.isEmpty else { return NSSound.beep() }   // its audio isn't on this Mac
        state.playingID = id
        playback.time = 0
        playback.duration = 0
        Task { @MainActor [weak self] in
            let timeline = AVMutableComposition()
            for url in files {
                let part = AVURLAsset(url: url)
                guard let length = try? await part.load(.duration) else { continue }
                try? await timeline.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: part, at: timeline.duration)
            }
            guard let self, self.state.playingID == id else { return }   // stopped while loading
            let item = AVPlayerItem(asset: timeline)
            let player = AVPlayer(playerItem: item)
            self.playback.duration = timeline.duration.seconds
            self.playback.seek = { [weak player] time in
                player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            self.playerClock = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] now in
                self?.playback.time = now.seconds
            }
            self.playerEnd = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                    object: item, queue: .main) { [weak self] _ in
                self?.stopPlayback()
            }
            self.player = player
            player.play()
        }
    }

    func stopPlayback() {
        player?.pause()
        if let playerClock { player?.removeTimeObserver(playerClock) }
        playerClock = nil
        player = nil
        playback.seek = { _ in }
        if let playerEnd { NotificationCenter.default.removeObserver(playerEnd) }
        playerEnd = nil
        state.playingID = nil
    }

    /// A transcript onto the clipboard (the watcher adds it to history like any copy),
    /// then close, and paste if asked.
    private func deliverText(_ text: String?, andPaste: Bool) {
        guard let text, !text.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        hide { [weak self] in if andPaste { self?.pasteIntoFrontApp() } }
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

    func pin(_ items: [ClipItem], to boardID: Int64) {
        items.forEach { DB.shared.pin($0, to: boardID) }
        if state.currentBoardID == boardID { state.reload(keepPosition: true) }
    }

    func pinToNewBoard(_ items: [ClipItem]) {
        let color = Board.presetColors[state.boards.count % Board.presetColors.count]
        let board = DB.shared.createBoard(name: "Untitled", colorHex: color)
        items.forEach { DB.shared.pin($0, to: board.id) }
        state.reload(keepPosition: true)
        if !state.searchOpen { state.renamingBoardID = board.id }   // search hides the chips
    }

    /// A card starts dragging: out to another app (as a file, text or link), or onto a
    /// pinboard tab. A card that's part of a multi-selection carries the whole selection.
    func beginDrag(_ item: ClipItem, at index: Int) -> NSItemProvider {
        dragged = state.selectedIndices.contains(index) && state.selectedIndices.count > 1
            ? state.selectedItems : [item]
        return DB.shared.itemProvider(for: item)
    }

    /// Pinboard tabs only take cards dragged from the panel, not drops from other apps.
    var isDraggingCards: Bool { !dragged.isEmpty }

    /// ponytail: SwiftUI reports no drag end, so after dragging a card out to another
    /// app, a drop from elsewhere onto a tab would still pin that card until the panel
    /// next shows or hides. Rare; a custom drag type would close it if it ever matters.
    func drop(onBoard id: Int64) -> Bool {
        guard !dragged.isEmpty else { return false }
        let items = dragged
        dragged = []
        items.forEach { DB.shared.pin($0, to: id) }
        // From one pinboard to another is a move, like dragging between folders. From the
        // clipboard history it's a copy: history keeps rolling on its own.
        if let from = state.currentBoardID, from != id { items.forEach { DB.shared.delete($0) } }
        // Follow the cards to their new board, selected (they're the newest, at the front).
        activateBoard(id)
        if !state.items.isEmpty {
            state.selectSingle(min(items.count, state.items.count) - 1)
            state.extend(to: 0)
        }
        return true
    }

    #if DEBUG
    /// Dev-only: render our own drawer to a PNG so the build loop can "see" it
    /// without Screen Recording permission. Vibrancy won't render; layout will.
    func snapshot() {
        if !isVisible { show() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard let view = panel.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            // Application Support is private to this user; /tmp isn't.
            try? rep.representation(using: .png, properties: [:])?
                .write(to: DB.supportDir.appendingPathComponent("copypasta-panel.png"))
        }
    }
    #endif

    func deleteItem(_ item: ClipItem) {
        let index = state.items.firstIndex(of: item) ?? state.selection
        DB.shared.delete(item)
        withAnimation(.easeOutStrong()) {
            state.reload(keepPosition: true)
            state.selectSingle(min(index, state.lastIndex))
        }
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

    /// Id of the editor's placeholder item while it writes a new one (⌘N).
    private static let newItemID: Int64 = -1

    /// ⌘N / ••• › New Text Item: the editor, empty; Save adds the text to the open tab.
    func newTextItem() {
        state.editText = ""
        state.editingItem = ClipItem(id: Self.newItemID, createdAt: Date(), kind: .text, plainText: "", rtf: nil,
                                     html: nil, imagePath: nil, thumb: nil, filePaths: [], sourceBundleID: nil,
                                     sourceAppName: "CopyPasta", contentHash: "", charCount: 0, pixelW: 0, pixelH: 0)
        removeKeyMonitor()
    }

    func saveEdit() {
        guard let item = state.editingItem else { return }
        guard item.id == Self.newItemID else {
            DB.shared.updateText(item, to: state.editText)
            endEditing()
            state.reload(keepPosition: true)    // keeps the edited card selected
            return
        }
        let text = state.editText
        endEditing()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Same hashing as a copy (a board item carries its board's suffix), so copying the
        // same text later bumps this item instead of adding a twin.
        let board = state.currentBoardID
        DB.shared.upsert(Capture(kind: .text, plainText: text, sourceAppName: "CopyPasta",
                                 contentHash: sha256(Data(text.utf8)) + (board.map { ":b\($0)" } ?? ""),
                                 charCount: text.count), boardID: board)
        state.reload()
    }

    // MARK: - ••• menu

    /// The ••• menu: an AppKit menu popped up by hand. (A SwiftUI Menu here lost its
    /// clicks: opening it took the key focus, which this never-activating panel took for
    /// a click elsewhere, and closed.) popUp returns only once the menu is gone, so the
    /// panel knows for the whole time that its own menu is open.
    func showMoreMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector, key: String = "", tag: Int = 0, symbol: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.tag = tag
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            return item
        }
        menu.addItem(item("About CopyPasta", #selector(menuAbout), symbol: "info.circle"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(menuSettings), key: ",", symbol: "gearshape"))
        menu.addItem(item("Check for Updates…", #selector(menuCheckForUpdates), symbol: "arrow.triangle.2.circlepath"))
        menu.addItem(.separator())
        let pause = item(state.isPaused ? "Paused" : "Pause CopyPasta", #selector(menuNothing), symbol: "pause.circle")
        let durations = NSMenu()
        for (title, minutes) in [("For 15 Minutes", 15), ("For 30 Minutes", 30), ("For 1 Hour", 60), ("For 3 Hours", 180), ("For 8 Hours", 480)] {
            durations.addItem(item(title, #selector(menuPause(_:)), tag: minutes * 60))
        }
        durations.addItem(.separator())
        durations.addItem(item(state.isPaused ? "Resume CopyPasta" : "Pause Until Resumed", #selector(menuTogglePause)))
        pause.submenu = durations
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(item("Quit CopyPasta", #selector(menuQuit), key: "q", symbol: "xmark.square"))

        guard let view = panel.contentView else { return }
        menuOpen = true
        let point = view.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: NSPoint(x: point.x - 4, y: point.y - 6), in: view)
        menuOpen = false
        if shown, !panel.isKeyWindow { panel.makeKey() }
    }

    @objc private func menuNothing() {}
    @objc private func menuAbout() { showAbout() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuCheckForUpdates() {
        hide()
        // AppDelegate's, from the updater (by name: it lives with the release setup).
        NSApp.sendAction(Selector(("checkForUpdates:")), to: NSApp.delegate, from: nil)
    }
    @objc private func menuPause(_ sender: NSMenuItem) { pause(for: TimeInterval(sender.tag)) }
    @objc private func menuTogglePause() { togglePause() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    /// ••• › About CopyPasta.
    func showAbout() {
        hide()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func cancelEdit() {
        endEditing()
    }

    private func endEditing() {
        state.editingItem = nil
        if isVisible { addKeyMonitor() }     // restore card navigation
    }
}
