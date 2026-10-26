import AppKit
import SwiftUI
import Carbon.HIToolbox

// Dev helpers: `Pastey --toggle` opens/closes the running instance's drawer,
// `Pastey --snapshot` writes its rendered view to /tmp/pastey-panel.png.
for (arg, name) in [("--toggle", "toggle"), ("--snapshot", "snapshot"), ("--settings", "settings")]
where CommandLine.arguments.contains(arg) {
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
        Notification.Name("com.marclamy.pastey.\(name)"),
        object: nil, userInfo: info, deliverImmediately: true
    )
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let watcher = ClipboardWatcher()
    var panelController: PanelController!
    var statusItem: NSStatusItem?
    var hotKey: HotKey?
    var pauseItem: NSMenuItem?
    var showItem: NSMenuItem?
    var settingsWindow: NSWindow?
    var pauseTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            forName: Notification.Name("com.marclamy.pastey.toggle"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.panelController.toggle()
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.marclamy.pastey.snapshot"),
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

        // Dev loop: `Pastey --settings` opens Settings and renders it to
        // /tmp/pastey-settings.png (same no-permission cacheDisplay trick as --snapshot).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.marclamy.pastey.settings"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.openSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let view = self?.settingsWindow?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/pastey-settings.png"))
            }
        }

        if settings.showInMenuBar { setupStatusItem() }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: watcher.isPaused ? "clipboard" : "clipboard.fill",
            accessibilityDescription: "Pastey"
        )

        let menu = NSMenu()

        // Title shows the shortcut as text only — the global hotkey is registered
        // once via Carbon (HotKey). Binding it here too would double-fire toggle().
        let show = NSMenuItem(title: "Show Pastey  \(AppSettings.shared.shortcutGlyphs)", action: #selector(toggleDrawer), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        showItem = show

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let pause = NSMenuItem(title: watcher.isPaused ? "Resume Watching" : "Pause Watching", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseItem = pause

        let clear = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Pastey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
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
        statusItem?.button?.image = NSImage(
            systemSymbolName: paused ? "clipboard" : "clipboard.fill",
            accessibilityDescription: "Pastey"
        )
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
        }
    }

    /// Registers the saved shortcut; false if another app holds it.
    @discardableResult
    func applyShortcut() -> Bool {
        let s = AppSettings.shared
        let registered = hotKey?.update(keyCode: s.shortcutKeyCode, modifiers: s.shortcutModifiers) ?? false
        s.shortcutUnavailable = !registered
        showItem?.title = "Show Pastey  \(s.shortcutGlyphs)"
        return registered
    }

    /// At launch: the shortcut is the only way into the panel, so don't let a clash
    /// with another clipboard app fail silently. (Settings › Shortcuts shows it too.)
    private func warnShortcutUnavailable() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(AppSettings.shared.shortcutGlyphs) is already in use"
        alert.informativeText = "Another app (Paste, Maccy, …) has this shortcut, so it won't open Pastey. Quit that app, or pick a different shortcut in Settings › Shortcuts."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    @objc private func menuOpenSettings() { openSettings() }

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            w.title = "Pastey Settings"
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua) // match the dark drawer
            w.center()
            w.contentView = NSHostingView(rootView: SettingsView())
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless() // accessory apps won't front reliably otherwise
    }

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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
