A clipboard history manager for macOS — a [Paste.app](https://pasteapp.io) clone opensource. Lives in the menu bar, remembers everything you copy, and brings it back with a keystroke.

- **Clipboard history** — text, links, images and files; search covers all of it
- **Boards** — organize snippets into pinboards (Prompts, Code, Useful Links, …)
- **Quick paste** — `⇧⌘V` opens the panel; type to search, `Enter` pastes straight into the app you were in
- **Multi-select** — `Shift`-click or `⇧←/→` a range, paste them all at once
- **Configurable retention** — keep history a day, week, month, year, or forever
- **Launch at login**, rebindable shortcut, hidden dock icon

## Requirements

- macOS 14 (Sonoma) or later
- [Xcode Command Line Tools](https://developer.apple.com/xcode/resources/) (provides Swift 5.9) — `xcode-select --install`

## Install

No prebuilt binary yet — build it from source (takes ~30s):

```bash
git clone https://github.com/marclelamy/copy-pasta.git
cd copy-pasta
./build.sh
open dist/Pastey.app
```

To install permanently, drag `dist/Pastey.app` into `/Applications`.

Pastey has no dock icon — it runs from the menu bar. Press `⇧⌘V` to open it.

The first time you press `Enter`, macOS asks to give Pastey **Accessibility** access. Pastey needs it to type `⌘V` into your app for you. Without it, `Enter` only copies the item and you paste it yourself. You can turn auto-paste off in Settings › General.

### Accessibility permission

macOS ties the permission to the app's code signature. `./build.sh` signs ad-hoc by default, and that signature changes on every build, so **each rebuild loses the permission**. System Settings still shows Pastey as enabled, but the permission no longer applies. To fix it, remove Pastey from the list with **−**, then grant access again.

To keep the permission across rebuilds, sign with a stable certificate once:

1. Open **Keychain Access** › menu **Keychain Access › Certificate Assistant › Create a Certificate…**
2. Name: `Pastey Dev`, Identity Type: **Self Signed Root**, Certificate Type: **Code Signing**, then **Create**
3. Build with `PASTEY_SIGN_IDENTITY="Pastey Dev" ./build.sh` (export it in your shell profile to make it stick)

> **Note:** the app is ad-hoc signed. Building it yourself (as above) is fine. If you instead download a prebuilt `.app`, macOS Gatekeeper will block it — right-click the app → **Open**, or run `xattr -dr com.apple.quarantine Pastey.app`.

## Usage

- **`⇧⌘V`** — open / close the panel (rebindable in Settings › Shortcuts)
- **Type** (or `⌘F`) — search everything in the current tab
- **`← →`** — move between cards; **`⌘← ⌘→`** — switch tabs
- **`Enter`** / double-click — paste the selection into the app you were in
- **`Shift`-click** / **`⇧← →`** — select a range to paste together
- **`⌘E`** — edit the selected text item; **`⌘⌫`** — delete the selection
- **Right-click a card** — paste, copy, pin to a board, delete
- **Click the open board** — rename it; **right-click a board** — rename, color, delete
- **Menu bar icon** — Settings, pause capture, quit

## Settings

Open from the menu bar icon → Settings:

- **General** — launch at login, auto-paste (and its Accessibility status), history retention, menu bar icon visibility
- **Shortcuts** — rebind the open/close hotkey. If another app (the real Paste, Maccy, …) already uses the shortcut, Pastey warns you here and at launch

## Importing from Paste.app

Migrating off the real Paste (Setapp)? `scripts/import_paste.py` pulls your text and link history across. Text/link items only — images and encrypted payloads are skipped, and items over 500 chars import truncated (Paste caps the cleartext preview). See the script header for the exact steps.

## Development

```bash
./build.sh run          # build + relaunch
Pastey --toggle         # open/close the running instance's panel
Pastey --snapshot       # render the panel to /tmp/pastey-panel.png
Pastey --settings       # open the Settings window
```

History is stored in a SQLite database at `~/Library/Application Support/Pastey/pastey.db`.
