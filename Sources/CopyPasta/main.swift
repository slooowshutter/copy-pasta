import AppKit
import SwiftUI
import Carbon.HIToolbox

// `CopyPasta benchmark --input <corpus>` compares dictation strategies on saved audio
// (`CopyPasta benchmark --help`). A command-line tool: runs, prints, exits; no app, no migrations.
if CommandLine.arguments.dropFirst().first == "benchmark" {
    Task {
        exit(await BenchmarkCommand.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
    }
    dispatchMain()
}

// `CopyPasta --toggle` opens/closes the running instance's drawer. Debug builds also have
// `--snapshot` / `--settings`, which render the drawer / Settings to PNGs in CopyPasta's
// private Application Support folder. Those stay out of release builds: any process can
// post these notifications, and a snapshot is a picture of the clipboard history.
#if DEBUG
let remoteHooks = [("--toggle", "toggle"), ("--snapshot", "snapshot"), ("--settings", "settings")]
#else
let remoteHooks = [("--toggle", "toggle")]
#endif
for (arg, name) in remoteHooks where CommandLine.arguments.contains(arg) {
    // `--snapshot --board Prompts` snapshots that tab.
    var info: [String: String] = [:]
    if let i = CommandLine.arguments.firstIndex(of: "--board"),
       i + 1 < CommandLine.arguments.count {
        info["board"] = CommandLine.arguments[i + 1]
    }
    if CommandLine.arguments.contains("--search") { info["search"] = "1" }
    if CommandLine.arguments.contains("--edit") { info["edit"] = "1" }
    if let i = CommandLine.arguments.firstIndex(of: "--select"),
       i + 1 < CommandLine.arguments.count {
        info["select"] = CommandLine.arguments[i + 1]
    }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.marclamy.copypasta.\(name)"),
        object: nil, userInfo: info, deliverImmediately: true
    )
    exit(0)
}

#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--render-cards"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { DevPreview.renderCards(to: CommandLine.arguments[i + 1]) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-tricks"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { DevPreview.renderTricks(to: CommandLine.arguments[i + 1]) }
    exit(0)
}
if CommandLine.arguments.contains("--check-migration") {
    RenameMigration.selfCheck()
    exit(0)
}
if CommandLine.arguments.contains("--check-copy-tricks") {
    CopyTricks.selfCheck()
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-settings"), i + 1 < CommandLine.arguments.count {
    let p = CommandLine.arguments.firstIndex(of: "--pane"), args = CommandLine.arguments
    let pane = p.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "General"
    MainActor.assumeIsolated { SettingsView.render(to: CommandLine.arguments[i + 1], pane: pane) }
    exit(0)
}
if CommandLine.arguments.contains("--check-dictation-import") {
    MainActor.assumeIsolated { SuperSamuelImport.selfCheck() }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-recordings"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { DevPreview.renderRecordings(to: CommandLine.arguments[i + 1]) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-panel"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { DevPreview.renderPanel(to: CommandLine.arguments[i + 1]) }
    exit(0)
}
#endif

RenameMigration.run() // Pastey → CopyPasta, before anything opens the database or settings
SuperSamuelImport.run() // SuperSamuel's dictation settings and data; after the rename, which may replace the folder

// `CopyPasta import-paste`: Paste's history and pinboards, into CopyPasta's (quit it first).
if CommandLine.arguments.dropFirst().first == "import-paste" {
    NSApplication.shared.setActivationPolicy(.prohibited)   // a command: no Dock icon, no window
    exit(PasteImport.run())
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let watcher = ClipboardWatcher()
    let copyTricks = CopyTricks()
    @MainActor lazy var dictation = DictationController() // created at launch, on the main actor
    private var dictationPhase: DictationPhase = .idle
    var panelController: PanelController!
    var statusItem: NSStatusItem?
    var hotKey: HotKey?
    var pauseItem: NSMenuItem?
    var showItem: NSMenuItem?
    var updateItem: NSMenuItem?
    var settingsWindow: NSWindow?
    var pauseTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        _ = DB.shared // open + migrate up-front, not lazily mid-use
        DB.shared.regenerateThumbnailsIfNeeded()
        panelController = PanelController(watcher: watcher)

        let settings = AppSettings.shared
        settings.onMenuBarChange = { [weak self] visible in self?.setMenuBarVisible(visible) }
        settings.onShortcutChange = { [weak self] in self?.applyShortcut() ?? false }
        DB.shared.pruneHistory(olderThan: settings.keepHistory.seconds) // enforce retention at launch

        watcher.onCapture = { [weak self] in
            guard let self, self.panelController.isVisible else { return }
            self.panelController.state.reload(keepPosition: true)
        }
        watcher.start()
        copyTricks.start()
        MainActor.assumeIsolated { startDictation() } // before the status item: its menu holds dictation's items

        // Default ⇧⌘V; user-rebindable in Settings › Shortcuts.
        hotKey = HotKey(keyCode: settings.shortcutKeyCode, modifiers: settings.shortcutModifiers) { [weak self] in
            self?.panelController.toggle()
        }
        settings.shortcutUnavailable = !(hotKey?.isRegistered ?? false)
        if settings.shortcutUnavailable {
            DispatchQueue.main.async { [weak self] in self?.warnShortcutUnavailable() }
        }
        // While another app holds the shortcut, take it back as soon as that app quits
        // (what the warnings tell the user to do). A beat first, for the window server to
        // release the quit app's hotkeys.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard AppSettings.shared.shortcutUnavailable else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.applyShortcut() }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.marclamy.copypasta.toggle"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.panelController.toggle()
        }

        #if DEBUG
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.marclamy.copypasta.snapshot"),
            object: nil, queue: .main
        ) { [weak self] note in
            // Optional board name in userInfo lets the dev loop snapshot a specific tab.
            if let name = note.userInfo?["board"] as? String,
               let board = self?.panelController.state.boards.first(where: { $0.name == name }) {
                self?.panelController.activateBoard(board.id)
            }
            self?.panelController.snapshot()
            if note.userInfo?["search"] as? String == "1" {
                self?.panelController.state.searchOpen = true
            }
            if let n = (note.userInfo?["select"] as? String).flatMap(Int.init), n > 0 {
                self?.panelController.state.selection = n - 1
                self?.panelController.state.selectedIndices = Set(0..<n)
            }
            if note.userInfo?["edit"] as? String == "1" {
                self?.panelController.beginEditing()
            }
        }

        // Dev loop: `CopyPasta --settings` opens Settings and renders it to
        // copypasta-settings.png in Application Support (same trick as --snapshot).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.marclamy.copypasta.settings"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.openSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let view = self?.settingsWindow?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = DB.supportDir.appendingPathComponent("copypasta-settings.png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path)
            }
        }
        #endif

        MainActor.assumeIsolated {
            Updater.shared.onChange = { [weak self] in self?.refreshUpdateItem() }
            Updater.shared.start() // checks once a day; off in builds without a Sparkle key
        }

        if settings.showInMenuBar { setupStatusItem() }
    }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        dictation.shutdown() // saves a recording in progress, for retry next launch
    }

    /// ⌥⇧⌘Space dictation (from the SuperSamuel app). The menu bar icon follows its phase.
    @MainActor private func startDictation() {
        dictation.onPhaseChange = { [weak self] phase in
            self?.dictationPhase = phase
            self?.refreshStatusIcon()
            if self?.panelController?.isVisible == true { self?.panelController.refreshRecordings() }
        }
        dictation.start()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        refreshStatusIcon()

        let menu = NSMenu()
        menu.delegate = self

        // Title shows the shortcut as text only — the global hotkey is registered
        // once via Carbon (HotKey). Binding it here too would double-fire toggle().
        let show = NSMenuItem(title: "Show CopyPasta  \(AppSettings.shared.shortcutGlyphs)", action: #selector(toggleDrawer), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        showItem = show

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        updateItem = update
        MainActor.assumeIsolated { refreshUpdateItem() }

        menu.addItem(.separator())
        MainActor.assumeIsolated { dictation.menuItems.forEach(menu.addItem) }
        menu.addItem(.separator())

        let pause = NSMenuItem(title: watcher.isPaused ? "Resume Watching" : "Pause Watching", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseItem = pause

        let clear = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit CopyPasta", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
    }

    @MainActor func menuWillOpen(_ menu: NSMenu) {
        dictation.menuWillOpen(menu) // unsent recordings, transcript history, checkmarks
        // Without Accessibility, ⌘C C / ⌘C C C can't see the keys and nothing gets pasted
        // for you, silently. Say so at the top of the menu until it's allowed.
        let tag = 0xACCE55
        menu.items.filter { $0.tag == tag }.forEach(menu.removeItem)
        guard !Paster.isTrusted else { return }
        let item = NSMenuItem(title: "Allow Accessibility for ⌘C C and pasting…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        let separator = NSMenuItem.separator()
        separator.tag = tag
        menu.insertItem(item, at: 0)
        menu.insertItem(separator, at: 1)
    }

    @objc private func openAccessibilitySettings() {
        Paster.requestAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Clipboard icon (outlined while paused); while dictating, the dictation phase
    /// (what SuperSamuel's own menu bar title showed).
    private func refreshStatusIcon() {
        let (symbol, label): (String, String)
        switch dictationPhase {
        case .recording:    (symbol, label) = ("mic.fill", "CopyPasta, recording")
        case .transcribing: (symbol, label) = ("waveform", "CopyPasta, transcribing")
        case .error:        (symbol, label) = ("exclamationmark.triangle", "CopyPasta, dictation needs attention")
        case .idle:         (symbol, label) = (watcher.isPaused ? "clipboard" : "clipboard.fill", "CopyPasta")
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    }

    @objc private func toggleDrawer() {
        panelController.toggle()
    }

    @objc func togglePause() {
        setPaused(!watcher.isPaused)
    }

    /// Pause capture, then auto-resume after `interval`.
    func pause(for interval: TimeInterval) {
        setPaused(true)
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.setPaused(false)
        }
    }

    /// Single source of truth for pause state — keeps the watcher, the drawer's
    /// menu label, and the status icon in sync.
    private func setPaused(_ paused: Bool) {
        watcher.isPaused = paused
        panelController?.state.isPaused = paused
        pauseItem?.title = paused ? "Resume Watching" : "Pause Watching"
        refreshStatusIcon()
        if !paused { pauseTimer?.invalidate(); pauseTimer = nil }
    }

    func setMenuBarVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil { setupStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            pauseItem = nil
            showItem = nil
            updateItem = nil
        }
    }

    /// "Check for Updates…" (status menu, and the panel's ••• menu by selector name).
    @MainActor @objc func checkForUpdates(_ sender: Any?) {
        Updater.shared.checkForUpdates()
    }

    /// Offers the update a background check found ("Update to 1.2.0…"), else "Check for Updates…".
    @MainActor private func refreshUpdateItem() {
        guard let item = updateItem else { return }
        let updater = Updater.shared
        item.title = updater.menuTitle
        item.image = updater.pendingVersion == nil
            ? nil : NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
        item.toolTip = updater.isEnabled ? nil : "This build doesn't update itself: it isn't a release build."
    }

    /// Registers the saved shortcut; false if another app holds it.
    @discardableResult
    func applyShortcut() -> Bool {
        let s = AppSettings.shared
        let registered = hotKey?.update(keyCode: s.shortcutKeyCode, modifiers: s.shortcutModifiers) ?? false
        s.shortcutUnavailable = !registered
        showItem?.title = "Show CopyPasta  \(s.shortcutGlyphs)"
        return registered
    }

    /// At launch: the shortcut is the only way into the panel, so don't let a clash
    /// with another clipboard app fail silently. (Settings › Shortcuts shows it too.)
    private func warnShortcutUnavailable() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(AppSettings.shared.shortcutGlyphs) is already in use"
        alert.informativeText = "Another app (Paste, Maccy, …) has this shortcut, so it won't open CopyPasta. Quit that app, or pick a different shortcut in Settings › Shortcuts."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    @objc private func menuOpenSettings() { openSettings() }

    /// `pane`: open on that pane ("Dictation"…), whatever was showing.
    func openSettings(pane: String? = nil) {
        if let pane, let settingsWindow {
            settingsWindow.contentView = NSHostingView(rootView: SettingsView(pane: pane, dictationStore: MainActor.assumeIsolated { .shared }))
        }
        if settingsWindow == nil {
            // SettingsWindow keeps the page scrolling when the pointer is over a text field
            // or editor (Settings › Dictation has two tall ones).
            let w = SettingsWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.title = "CopyPasta Settings"
            // Paste's look: no visible title bar; an empty unified toolbar makes it tall
            // enough that the window buttons sit inside the sidebar (SettingsView).
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.titlebarSeparatorStyle = .none
            w.toolbar = NSToolbar(identifier: "settings")
            w.toolbarStyle = .unified
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua) // match the dark drawer
            w.center()
            w.contentView = NSHostingView(rootView: pane.map { p in SettingsView(pane: p, dictationStore: MainActor.assumeIsolated { .shared }) } ?? SettingsView())
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless() // accessory apps won't front reliably otherwise
    }

    /// An app menu and an Edit menu. CopyPasta never shows a menu bar (it's a menu bar app),
    /// but key equivalents go through this menu: without Edit, ⌘C / ⌘V / ⌘A / ⌘Z did nothing
    /// in Settings' text fields.
    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About CopyPasta",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide CopyPasta", action: #selector(hideApp(_:)), keyEquivalent: "h").target = self
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(hideOtherApps(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = self
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit CopyPasta", action: #selector(quitApp(_:)), keyEquivalent: "q").target = self
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func hideApp(_ sender: Any?) { NSApp.hide(sender) }
    @objc private func hideOtherApps(_ sender: Any?) { NSApp.hideOtherApplications(sender) }
    @objc private func quitApp(_ sender: Any?) { NSApp.terminate(sender) }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This deletes your whole clipboard history, including images. Items pinned to pinboards are kept. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            DB.shared.clearAll()
            panelController.state.reload()
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// ⌘Q, ⌘H and ⌥⌘H do nothing while the clipboard panel is open, as before CopyPasta had
    /// a main menu: the panel floats over another app, and that app is the one the user
    /// means to quit or hide.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates(_:)) {
            return MainActor.assumeIsolated { Updater.shared.canCheckForUpdates }
        }
        let panelShortcuts = [#selector(quitApp(_:)), #selector(hideApp(_:)), #selector(hideOtherApps(_:))]
        guard let action = item.action, panelShortcuts.contains(action) else { return true }
        return !(panelController?.isVisible ?? false)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
