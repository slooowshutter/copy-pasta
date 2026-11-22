# To do

Next steps for CopyPasta, most important first (22 Nov 2026).

## Test week (from 22 Nov)

Use CopyPasta day to day for a week; write what breaks or feels wrong here, then fix it in a new workspace.

- …

## Next

- [ ] **Make dictation reliable.** It's why SuperSamuel is still installed. Of the 26 recordings waiting in the Recordings tab:
  - 9 failed with "the transcription service returned no text". It's the most common failure, and all 4 failed recordings saved in several parts are among them.
  - 6 "no speech detected", 5 "processing cancelled", 3 network errors, 1 "audio file might be corrupted" (HTTP 400), 1 microphone didn't start, 1 interrupted when the app quit.

  Reproduce with their saved audio (`CopyPasta benchmark`), fix the cause, then retry them from the Recordings tab.
- [ ] **Turn on real updates.** Needs a Developer ID certificate, the Sparkle key in `Info.plist`, a first GitHub release and the Homebrew tap (README › Releasing). Until then, Check for Updates… only says this copy can't update itself.
- [ ] Smaller:
  - a "Clear failed" action for old recordings in the Recordings tab
  - the final app icon
  - once SuperSamuel is retired: give CopyPasta its ⌥Space shortcut?
  - bring over the four words in SuperSamuel's older vocabulary list (it no longer reads them) into the personal dictionary?

## Decided

- The name stays CopyPasta.
- The typo fix drawn on the text (⌘C C C) works; nothing to fix.
- SuperSamuel gets retired by hand (quit it, remove it from Login Items).
