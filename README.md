A clipboard history manager for macOS — a [Paste.app](https://pasteapp.io) clone opensource. Lives in the menu bar, remembers everything you copy, and brings it back with a keystroke.

- **Clipboard history** — every text/link you copy, searchable
- **Boards** — organize snippets into pinboards (Prompts, Code, Useful Links, …)
- **Quick paste** — `⇧⌘V` opens the panel; type to search, `Enter` to paste
- **Multi-select** — `Shift`-click a range, paste them all at once
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

> **Note:** the app is ad-hoc signed. Building it yourself (as above) is fine. If you instead download a prebuilt `.app`, macOS Gatekeeper will block it — right-click the app → **Open**, or run `xattr -dr com.apple.quarantine Pastey.app`.

## Usage

- **`⇧⌘V`** — open / close the panel (rebindable in Settings › Shortcuts)
- **Type** — filter history
- **`Enter`** — paste the selection
- **`Shift`-click** — select a range to paste together
- **Menu bar icon** — Settings, pause capture, quit

## Settings

Open from the menu bar icon → Settings:

- **General** — launch at login, history retention, menu bar icon visibility
- **Shortcuts** — rebind the open/close hotkey

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
