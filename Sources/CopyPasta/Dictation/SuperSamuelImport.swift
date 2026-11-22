import Foundation

/// Where dictation keeps its data: ~/Library/Application Support/CopyPasta/Dictation, with
/// `Recordings` (unsent recordings) and `Transcript History` inside.
enum DictationStorage {
    static let folder = "CopyPasta/Dictation"

    static var root: URL {
        applicationSupport.appendingPathComponent(folder, isDirectory: true)
    }

    static var applicationSupport: URL {
        let fileManager = FileManager.default
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}

/// SuperSamuel, the dictation app, is now part of CopyPasta. On the first launch, bring its
/// settings, unsent recordings and transcript history across. Copy, never move or delete:
/// SuperSamuel may still be installed and in use. Its API keys come over the first time
/// CopyPasta reads them (SharedAPIKey). Runs after RenameMigration, before the app starts.
enum SuperSamuelImport {
    static let bundleID = "com.supersamuel.app"

    static var supportDirectory: URL {
        DictationStorage.applicationSupport.appendingPathComponent("SuperSamuel", isDirectory: true)
    }

    /// Over this much data (as Finder counts: 1 GB = 10⁹ bytes), the audio of past
    /// transcripts stays in SuperSamuel's folder and only their text and details come over.
    /// Only where copying means copying: on APFS (any Mac's own disk) a copy is a clone,
    /// instant and taking no space, so everything comes over, audio included.
    static var audioLimit: Int64 {
        let volume = try? DictationStorage.applicationSupport.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
        return volume?.volumeSupportsFileCloning == true ? .max : 1_000_000_000
    }

    /// Every setting SuperSamuel's SettingsStore reads. Each lands in CopyPasta's defaults
    /// under the same name with a "dictation." prefix. Not copied: `usesLocalCredentials`
    /// (CopyPasta always keeps keys in private files) and keys older SuperSamuel versions
    /// left behind that nothing reads any more.
    static let settingKeys = [
        "autoPaste", "restoreClipboard",
        "realtimeTranscriptionEnabled", "realtimeTranscriptionDelay", "personalDictionary",
        "openRouterTranscriptionModel", "openRouterTranscriptionContext", "openRouterCleanupPrompt",
        "transcriptCleanupEnabled", "transcriptCleanupModel", "transcriptCleanupInstructions",
        "minimalCleanupPromptInstalled", "gemmaCleanupDefaultInstalled",
        "openRouterAPIKey", // pre-Keychain versions kept the key here; SettingsStore moves it to a file
    ]

    static let settingsImportedKey = SettingsStore.Keys.prefix + "importedSuperSamuelSettings"
    /// Set when the history came over without its audio, so Settings can say where it is.
    static let audioLeftBehindKey = SettingsStore.Keys.prefix + "superSamuelAudioLeftBehind"
    /// Written into CopyPasta's Dictation folder once each folder has come over. Kept there
    /// rather than in the defaults: if that folder is ever replaced, its import runs again.
    static let recordingsMarker = ".supersamuel-recordings-imported"
    static let historyMarker = ".supersamuel-history-imported"

    private static let audioExtensions: Set<String> = ["m4a", "wav"]

    static func run() {
        guard Bundle.main.bundleIdentifier == "com.marclamy.copypasta",
              let domain = Bundle.main.bundleIdentifier else { return }
        let defaults = UserDefaults.standard
        copySettings(from: defaults.persistentDomain(forName: bundleID), into: defaults, domain: domain)
        let source = supportDirectory, destination = DictationStorage.root
        // Unsent recordings are few and small, and dictation offers to send them at launch.
        report(copyRecordings(from: source, to: destination))
        // A long-used history is tens of thousands of small files (8 s on a real one), so it
        // comes over after launch, off the main thread. The menu lists entries as they land.
        DispatchQueue.global(qos: .utility).async {
            let outcome = copyHistory(from: source, to: destination)
            if outcome.historyAudioLeftBehind { UserDefaults.standard.set(true, forKey: audioLeftBehindKey) }
            report(outcome)
        }
    }

    private static func report(_ outcome: Outcome) {
        guard let summary = outcome.summary else { return }
        NSLog("CopyPasta: %@", summary)
        plog(summary)
    }

    // MARK: Settings

    /// Once. A setting CopyPasta already has is never overwritten.
    static func copySettings(from old: [String: Any]?, into defaults: UserDefaults, domain: String) {
        guard !defaults.bool(forKey: settingsImportedKey) else { return }
        let existing = defaults.persistentDomain(forName: domain) ?? [:]
        for key in settingKeys {
            let newKey = SettingsStore.Keys.prefix + key
            guard existing[newKey] == nil, let value = old?[key] else { continue }
            defaults.set(value, forKey: newKey)
        }
        defaults.set(true, forKey: settingsImportedKey)
    }

    // MARK: Recordings and transcript history

    struct Outcome: Equatable {
        var alreadyDone = false
        var recordingsBytes: Int64 = 0
        var historyBytes: Int64 = 0
        var recordingsCopied = false
        var historyCopied = false
        var historyAudioLeftBehind = false
        var failures = 0

        var summary: String? {
            guard !alreadyDone, recordingsCopied || historyCopied || failures > 0 else { return nil }
            var parts = ["copied SuperSamuel's dictation data"]
            if recordingsCopied { parts.append("unsent recordings (\(format(recordingsBytes)))") }
            if historyCopied { parts.append("transcript history (\(format(historyBytes)))") }
            if !recordingsCopied, recordingsBytes > 0 {
                parts.append("unsent recordings skipped: over \(format(audioLimit))")
            }
            if historyAudioLeftBehind {
                parts.append("over \(format(audioLimit)) in total, so the history's audio stayed in \(supportDirectory.path)")
            }
            if failures > 0 { parts.append("\(failures) item(s) failed, will retry next launch") }
            return parts.joined(separator: "; ")
        }

        private func format(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    // Each folder is copied entry by entry: an entry is cloned (APFS: instant, and no extra
    // space) under a hidden name the stores ignore, then renamed into place, and entries
    // already there are skipped. The folder's marker goes last, after a clean run, so an
    // interrupted or failed import finishes on the next launch. Once the marker exists nothing
    // is copied again: recordings and transcripts deleted in CopyPasta stay deleted.

    /// SuperSamuel's unsent recordings. Each is nothing but its audio, so they come over
    /// whole, or not at all if they're over the limit by themselves.
    @discardableResult
    static func copyRecordings(from source: URL, to destination: URL, audioLimit: Int64 = audioLimit) -> Outcome {
        var outcome = Outcome()
        let marker = destination.appendingPathComponent(recordingsMarker)
        if FileManager.default.fileExists(atPath: marker.path) {
            outcome.alreadyDone = true
            return outcome
        }
        let old = source.appendingPathComponent("Recordings", isDirectory: true)
        outcome.recordingsBytes = size(of: old)
        if outcome.recordingsBytes <= audioLimit, FileManager.default.fileExists(atPath: old.path) {
            outcome.failures = copyEntries(
                of: old, into: destination.appendingPathComponent("Recordings", isDirectory: true), withoutAudio: false)
            outcome.recordingsCopied = true
        }
        finish(&outcome, marker: marker, in: destination)
        return outcome
    }

    /// SuperSamuel's transcript history. If it and the unsent recordings come to more than
    /// the limit, the transcripts come over without their audio.
    @discardableResult
    static func copyHistory(from source: URL, to destination: URL, audioLimit: Int64 = audioLimit) -> Outcome {
        var outcome = Outcome()
        let marker = destination.appendingPathComponent(historyMarker)
        if FileManager.default.fileExists(atPath: marker.path) {
            outcome.alreadyDone = true
            return outcome
        }
        let old = source.appendingPathComponent("Transcript History", isDirectory: true)
        outcome.historyBytes = size(of: old)
        let recordingsBytes = size(of: source.appendingPathComponent("Recordings", isDirectory: true))
        let total = (recordingsBytes <= audioLimit ? recordingsBytes : 0) + outcome.historyBytes
        outcome.historyAudioLeftBehind = total > audioLimit && hasAudio(old)
        if FileManager.default.fileExists(atPath: old.path) {
            outcome.failures = copyEntries(
                of: old, into: destination.appendingPathComponent("Transcript History", isDirectory: true),
                withoutAudio: outcome.historyAudioLeftBehind)
            outcome.historyCopied = true
        }
        finish(&outcome, marker: marker, in: destination)
        return outcome
    }

    private static func finish(_ outcome: inout Outcome, marker: URL, in destination: URL) {
        guard outcome.failures == 0 else { return }
        do {
            try makePrivateDirectory(destination)
            try Data(((outcome.summary ?? "nothing to copy") + "\n").utf8).write(to: marker, options: .atomic)
        } catch {
            outcome.failures += 1
            NSLog("CopyPasta: importing SuperSamuel's dictation data failed, will retry next launch: \(error)")
        }
    }

    /// Returns the number of entries that failed.
    private static func copyEntries(of source: URL, into destination: URL, withoutAudio: Bool) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 1 }
        do { try makePrivateDirectory(destination) } catch { return 1 }

        var failures = 0
        for entry in entries {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            if fm.fileExists(atPath: target.path) { continue }
            let staging = destination.appendingPathComponent(".importing-" + entry.lastPathComponent)
            try? fm.removeItem(at: staging) // left by an interrupted launch
            do {
                try clone(entry, to: staging)
                if withoutAudio { try removeAudio(in: staging) }
                try fm.moveItem(at: staging, to: target)
            } catch {
                try? fm.removeItem(at: staging)
                failures += 1
                NSLog("CopyPasta: couldn't copy \(entry.path): \(error)")
            }
        }
        return failures
    }

    /// APFS clone of a file or a whole folder; a regular copy where cloning isn't possible
    /// (another volume, another file system).
    private static func clone(_ source: URL, to target: URL) throws {
        if clonefile(source.path, target.path, 0) == 0 { return }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
    }

    private static func removeAudio(in item: URL) throws {
        if isAudio(item) { return try FileManager.default.removeItem(at: item) }
        guard let files = FileManager.default.enumerator(at: item, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where isAudio(file) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func isAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    private static func hasAudio(_ folder: URL) -> Bool {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
        for case let file as URL in files where isAudio(file) { return true }
        return false
    }

    /// Total size of the regular files in `folder` (0 if it doesn't exist).
    static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    #if DEBUG
    /// Removing a suite's domain still leaves an empty plist in ~/Library/Preferences.
    static func removeDefaultsSuite(_ suite: String) {
        let defaults = UserDefaults(suiteName: suite)
        defaults?.removePersistentDomain(forName: suite)
        defaults?.synchronize()
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist"))
    }

    /// Both folders, one after the other (the app copies the history in the background).
    @discardableResult
    static func copyData(from source: URL, to destination: URL, audioLimit: Int64 = audioLimit) -> Outcome {
        let recordings = copyRecordings(from: source, to: destination, audioLimit: audioLimit)
        var outcome = copyHistory(from: source, to: destination, audioLimit: audioLimit)
        outcome.alreadyDone = recordings.alreadyDone && outcome.alreadyDone
        outcome.recordingsBytes = recordings.recordingsBytes
        outcome.recordingsCopied = recordings.recordingsCopied
        outcome.failures += recordings.failures
        return outcome
    }

    /// `CopyPasta --check-dictation-import`: runs the import on throwaway folders and asserts
    /// what comes over, what stays behind, and that SuperSamuel's own data is untouched.
    @MainActor
    static func selfCheck() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("copypasta-dictation-import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func write(_ text: String, _ url: URL) {
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(text.utf8).write(to: url)
        }
        func exists(_ url: URL, _ path: String) -> Bool { fm.fileExists(atPath: url.appendingPathComponent(path).path) }
        /// A SuperSamuel folder: one unsent recording, one archived transcript (with audio,
        /// written by the real TranscriptHistoryStore), one legacy flat transcript.
        func makeSuperSamuel(_ dir: URL) -> (pending: UUID, archived: UUID, legacy: UUID) {
            let recordings = RecordingStore(rootDirectory: dir)
            let pending = try! recordings.createSession(transcriptionModel: "openai/gpt-transcribe")
            let chunk = try! recordings.beginChunk(in: pending.id)
            try! Data(repeating: 1, count: 300).write(to: chunk)
            try! recordings.finishCurrentChunk(in: pending.id, duration: 2)
            try! recordings.markReady(pending.id, message: "Kept for later")

            let archived = UUID()
            let session = dir.appendingPathComponent("Transcript History/\(archived.uuidString)")
            write(String(repeating: "a", count: 400), session.appendingPathComponent("chunk-0001.m4a"))
            write("Hello from SuperSamuel.", session.appendingPathComponent("transcript.txt"))
            let createdAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000))
            write("""
            {"schemaVersion":1,"id":"\(archived.uuidString)","createdAt":"\(createdAt)","completedAt":"\(createdAt)",
             "text":"Hello from SuperSamuel.","transcriptFilename":"transcript.txt",
             "workflow":{"workflow":"transcription-only","usedScreenshotContext":false},
             "audio":[],"operatingSystem":"macOS"}
            """, session.appendingPathComponent("metadata.json"))
            let legacy = UUID()
            write(#"{"id":"\#(legacy.uuidString)","createdAt":"\#(createdAt)","text":"Legacy transcript."}"#,
                  dir.appendingPathComponent("Transcript History/\(legacy.uuidString).json"))
            write("finder", dir.appendingPathComponent("Transcript History/.DS_Store"))
            return (pending.id, archived, legacy)
        }

        // 1. Under the limit: everything comes over, audio included; SuperSamuel's data stays.
        var old = root.appendingPathComponent("1/SuperSamuel"), new = root.appendingPathComponent("1/Dictation")
        var ids = makeSuperSamuel(old)
        let oldSize = size(of: old)
        var outcome = copyData(from: old, to: new)
        assert(outcome.recordingsCopied && outcome.historyCopied && !outcome.historyAudioLeftBehind && outcome.failures == 0)
        assert(exists(new, "Recordings/\(ids.pending.uuidString)/chunk-0001.m4a"), "unsent recording missing")
        assert(exists(new, "Transcript History/\(ids.archived.uuidString)/chunk-0001.m4a"), "history audio missing")
        assert(exists(new, "Transcript History/\(ids.legacy.uuidString).json"))
        assert(!exists(new, "Transcript History/.DS_Store"), "hidden files must not come over")
        assert(exists(new, recordingsMarker) && exists(new, historyMarker))
        assert(size(of: old) == oldSize && exists(old, "Recordings/\(ids.pending.uuidString)/chunk-0001.m4a"),
               "SuperSamuel's data must be left as it was")
        // CopyPasta's stores read what came over.
        let pending = try! RecordingStore(rootDirectory: new).pendingSessions()
        assert(pending.map(\.id) == [ids.pending] && pending[0].status == .ready)
        let history = TranscriptHistoryStore(rootDirectory: new)
        assert(try! history.item(id: ids.archived)?.text == "Hello from SuperSamuel.")
        assert(try! history.item(id: ids.legacy)?.text == "Legacy transcript.")

        // 2. Done once: what the user deletes in CopyPasta doesn't come back next launch.
        try! fm.removeItem(at: new.appendingPathComponent("Transcript History/\(ids.archived.uuidString)"))
        outcome = copyData(from: old, to: new)
        assert(outcome.alreadyDone && !exists(new, "Transcript History/\(ids.archived.uuidString)"))

        // 2b. Quit while the history was still copying (in the background): the next launch
        //     finishes it, and a recording trashed in the meantime stays trashed.
        old = root.appendingPathComponent("2b/SuperSamuel"); new = root.appendingPathComponent("2b/Dictation")
        ids = makeSuperSamuel(old)
        copyRecordings(from: old, to: new)
        try! fm.removeItem(at: new.appendingPathComponent("Recordings/\(ids.pending.uuidString)")) // as Move to Trash does
        assert(!exists(new, historyMarker) && !exists(new, "Recordings/\(ids.pending.uuidString)"))
        outcome = copyData(from: old, to: new)
        assert(outcome.historyCopied && !outcome.recordingsCopied && exists(new, historyMarker))
        assert(!exists(new, "Recordings/\(ids.pending.uuidString)"), "a trashed recording came back")
        assert(exists(new, "Transcript History/\(ids.archived.uuidString)/metadata.json"))

        // 3. Over the limit: unsent recordings still come over, the history without its audio.
        old = root.appendingPathComponent("3/SuperSamuel"); new = root.appendingPathComponent("3/Dictation")
        ids = makeSuperSamuel(old)
        let recordingsSize = size(of: old.appendingPathComponent("Recordings"))
        assert(recordingsSize > 300 && size(of: old) > recordingsSize + 400)
        outcome = copyData(from: old, to: new, audioLimit: recordingsSize + 1)
        assert(outcome.recordingsCopied && outcome.historyCopied && outcome.historyAudioLeftBehind)
        assert(exists(new, "Recordings/\(ids.pending.uuidString)/chunk-0001.m4a"))
        assert(!exists(new, "Transcript History/\(ids.archived.uuidString)/chunk-0001.m4a"), "audio over the limit must stay behind")
        assert(exists(new, "Transcript History/\(ids.archived.uuidString)/transcript.txt"))
        assert(exists(old, "Transcript History/\(ids.archived.uuidString)/chunk-0001.m4a"))
        assert(try! TranscriptHistoryStore(rootDirectory: new).item(id: ids.archived)?.text == "Hello from SuperSamuel.")
        assert(outcome.summary?.contains("stayed in") == true)

        // 4. Unsent recordings alone over the limit: skipped, the history still comes over.
        old = root.appendingPathComponent("4/SuperSamuel"); new = root.appendingPathComponent("4/Dictation")
        ids = makeSuperSamuel(old)
        outcome = copyData(from: old, to: new, audioLimit: recordingsSize - 1)
        assert(!outcome.recordingsCopied && outcome.historyCopied && outcome.historyAudioLeftBehind)
        assert(!exists(new, "Recordings/\(ids.pending.uuidString)"))
        assert(exists(new, "Transcript History/\(ids.legacy.uuidString).json"))

        // 5. Interrupted earlier (a half-copied entry under its hidden name, one entry done,
        //    no marker): the rerun finishes the job without duplicating anything.
        old = root.appendingPathComponent("5/SuperSamuel"); new = root.appendingPathComponent("5/Dictation")
        ids = makeSuperSamuel(old)
        write("partial", new.appendingPathComponent("Transcript History/.importing-\(ids.archived.uuidString)/transcript.txt"))
        try! fm.createDirectory(at: new.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
        try! fm.copyItem(at: old.appendingPathComponent("Recordings/\(ids.pending.uuidString)"),
                         to: new.appendingPathComponent("Recordings/\(ids.pending.uuidString)"))
        outcome = copyData(from: old, to: new)
        assert(outcome.failures == 0 && exists(new, recordingsMarker) && exists(new, historyMarker))
        assert(!exists(new, "Transcript History/.importing-\(ids.archived.uuidString)"), "staging left behind")
        assert(exists(new, "Transcript History/\(ids.archived.uuidString)/metadata.json"))
        assert(try! RecordingStore(rootDirectory: new).pendingSessions().count == 1)

        // 6. No SuperSamuel: nothing to copy, marked done.
        new = root.appendingPathComponent("6/Dictation")
        outcome = copyData(from: root.appendingPathComponent("6/SuperSamuel"), to: new)
        assert(!outcome.recordingsCopied && !outcome.historyCopied)
        assert(exists(new, recordingsMarker) && exists(new, historyMarker))

        // 7. Settings: copied once under "dictation."; CopyPasta's own values win; the
        //    SettingsStore reads them; a saved model choice is kept.
        let suite = "copypasta-dictation-import-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeDefaultsSuite(suite) }
        defaults.set(false, forKey: "dictation.restoreClipboard")
        defaults.set("keep", forKey: "showInMenuBar")
        let superSamuel: [String: Any] = [
            "autoPaste": false, "restoreClipboard": true, "realtimeTranscriptionDelay": "minimal",
            "personalDictionary": ["Claude Code", "tryblend"], "transcriptCleanupEnabled": true,
            "transcriptCleanupModel": "openai/gpt-oss-120b:nitro", "minimalCleanupPromptInstalled": true,
            "gemmaCleanupDefaultInstalled": true, "usesLocalCredentials": true, "showInMenuBar": "SuperSamuel's",
        ]
        copySettings(from: superSamuel, into: defaults, domain: suite)
        assert(defaults.object(forKey: "dictation.autoPaste") as? Bool == false)
        assert(defaults.bool(forKey: "dictation.restoreClipboard") == false, "CopyPasta's own value must win")
        assert(defaults.string(forKey: "showInMenuBar") == "keep", "only dictation keys may change")
        assert(defaults.object(forKey: "dictation.usesLocalCredentials") == nil)
        assert(defaults.object(forKey: "usesLocalCredentials") == nil && defaults.object(forKey: "autoPaste") == nil)
        defaults.set(true, forKey: "dictation.autoPaste")
        copySettings(from: superSamuel, into: defaults, domain: suite)
        assert(defaults.bool(forKey: "dictation.autoPaste"), "settings must be copied only once")
        let keys = root.appendingPathComponent("keys")
        let settings = SettingsStore(defaults: defaults,
                                     credentials: SharedAPIKey(store: CredentialStore(service: suite, localDirectory: keys)),
                                     openAICredentials: SharedAPIKey(store: CredentialStore(service: suite, account: "openai", localDirectory: keys)))
        assert(settings.transcriptionDelay == .minimal && settings.cleanupEnabled)
        assert(settings.personalDictionary == ["Claude Code", "tryblend"])
        assert(settings.cleanupModel == "openai/gpt-oss-120b:nitro")

        // 8. Keys: SuperSamuel's come over on first read; one the user cleared stays cleared.
        let oldKeys = root.appendingPathComponent("SuperSamuel/Credentials")
        let oldKey = CredentialStore(service: bundleID, account: "openrouter-api-key", localDirectory: oldKeys)
        try! oldKey.writeAPIKey("sk-or-from-supersamuel", useLocalStorage: true)
        let shared = SharedAPIKey(store: CredentialStore(service: suite, account: "openrouter-api-key", localDirectory: keys),
                                  superSamuel: oldKey)
        assert(shared.read() == "sk-or-from-supersamuel")
        try! shared.write("")
        assert(shared.read() == nil, "a cleared key must not be imported again")
        assert(oldKey.readAPIKey(useLocalStorage: true) == "sk-or-from-supersamuel")

        print("dictation import check passed")
    }
    #endif
}
