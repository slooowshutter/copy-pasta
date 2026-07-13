import AppKit
import Carbon.HIToolbox

// Dev helpers: `Pastey --toggle` opens/closes the running instance's drawer,
// `Pastey --snapshot` writes its rendered view to /tmp/pastey-panel.png.
for (arg, name) in [("--toggle", "toggle"), ("--snapshot", "snapshot")]
where CommandLine.arguments.contains(arg) {
    // `--snapshot --board Prompts` snapshots that tab.
    var info: [String: String] = [:]
    if let i = CommandLine.arguments.firstIndex(of: "--board"),
       i + 1 < CommandLine.arguments.count {
        info["board"] = CommandLine.arguments[i + 1]
    }
    if CommandLine.arguments.contains("--search") { info["search"] = "1" }
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
    var statusItem: NSStatusItem!
    var hotKey: HotKey?
    var pauseItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = DB.shared // open + migrate up-front, not lazily mid-use
        DB.shared.regenerateThumbnailsIfNeeded()
        panelController = PanelController()

        watcher.onCapture = { [weak self] in
            guard let self, self.panelController.isVisible else { return }
            self.panelController.state.reload()
        }
        watcher.start()

        // ⌘⌥⇧V while testing — real Paste owns ⌘⇧V; reclaim it when Pastey replaces Paste.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey | shiftKey)) { [weak self] in
            self?.panelController.toggle()
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
        }

        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "clipboard.fill",
            accessibilityDescription: "Pastey"
        )

        let menu = NSMenu()

        // Title shows the shortcut as text only — the global hotkey is registered
        // once via Carbon (HotKey). Binding it here too would double-fire toggle().
        let show = NSMenuItem(title: "Show Pastey  ⌥⇧⌘V", action: #selector(toggleDrawer), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())

        pauseItem = NSMenuItem(title: "Pause Watching", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let clear = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Pastey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleDrawer() {
        panelController.toggle()
    }

    @objc private func togglePause() {
        watcher.isPaused.toggle()
        pauseItem.title = watcher.isPaused ? "Resume Watching" : "Pause Watching"
        statusItem.button?.image = NSImage(
            systemSymbolName: watcher.isPaused ? "clipboard" : "clipboard.fill",
            accessibilityDescription: "Pastey"
        )
    }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This deletes every stored item, including images. This cannot be undone."
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
