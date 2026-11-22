import AppKit
import SQLite3

/// CopyPasta used to be called Pastey. On the first launch under the new name, bring
/// everything across: quit the old app, move its folder (history, images, log) to the
/// new name, and copy its settings. Runs before anything opens the database, and only
/// in the real app bundle (a dev build run from the terminal must not quit Pastey).
enum RenameMigration {
    private static let oldBundleID = "com.marclamy.pastey"

    static func run() {
        guard Bundle.main.bundleIdentifier == "com.marclamy.copypasta" else { return }
        copySettings()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        moveHistory(from: support.appendingPathComponent("Pastey", isDirectory: true),
                    to: support.appendingPathComponent("CopyPasta", isDirectory: true),
                    beforeMoving: quitOldApp)
    }

    /// Pastey's folder becomes CopyPasta's, unless CopyPasta already has a history.
    static func moveHistory(from old: URL, to new: URL, beforeMoving: () -> Void) {
        let fm = FileManager.default
        let oldDB = old.appendingPathComponent("pastey.db")
        guard fm.fileExists(atPath: oldDB.path), isEmpty(new.appendingPathComponent("copypasta.db")) else { return }

        beforeMoving()
        // Fold the write-ahead log into the database file and close it, so the whole
        // history is one file to move (moving a database and its log separately could
        // drop recent copies).
        var db: OpaquePointer?
        if sqlite3_open(oldDB.path, &db) == SQLITE_OK {
            sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        }
        sqlite3_close(db)

        do {
            // Rename inside the old folder first, then move the folder in one step: if
            // anything fails, the old folder is still there and the next launch retries.
            for (from, to) in [("pastey.db", "copypasta.db"), ("pastey.db-wal", "copypasta.db-wal"),
                               ("pastey.db-shm", "copypasta.db-shm"), ("pastey.log", "copypasta.log")] {
                let source = old.appendingPathComponent(from)
                if fm.fileExists(atPath: source.path) {
                    try fm.moveItem(at: source, to: old.appendingPathComponent(to))
                }
            }
            if fm.fileExists(atPath: new.path) {
                // CopyPasta already ran with an empty history (an earlier move failed): merge.
                // Pastey's history replaces the empty database; everything else CopyPasta saved
                // meanwhile (dictations, keys) stays, and Pastey's other items join it.
                for name in try fm.contentsOfDirectory(atPath: old.path) {
                    let source = old.appendingPathComponent(name), target = new.appendingPathComponent(name)
                    if name.hasPrefix("copypasta.db") {
                        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    } else if fm.fileExists(atPath: target.path) {
                        continue
                    }
                    try fm.moveItem(at: source, to: target)
                }
                // A leftover empty database's WAL files, if Pastey had none to replace them.
                for suffix in ["-wal", "-shm"] where !fm.fileExists(atPath: old.appendingPathComponent("copypasta.db" + suffix).path) {
                    try? fm.removeItem(at: new.appendingPathComponent("copypasta.db" + suffix))
                }
                try? fm.removeItem(at: old)
            } else {
                try fm.moveItem(at: old, to: new)
            }
        } catch {
            NSLog("CopyPasta: moving Pastey's history failed, will retry next launch: \(error)")
        }
    }

    /// No database yet, or one with nothing in it (a launch before the move created it):
    /// either way there's nothing to lose by replacing it with Pastey's history.
    private static func isEmpty(_ dbURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return true }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT (SELECT COUNT(*) FROM items) + (SELECT COUNT(*) FROM boards)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int64(stmt, 0) == 0
    }

    /// Pastey and CopyPasta must not write the same history at once.
    private static func quitOldApp() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// Shortcut, retention, background style… once, while CopyPasta has none of its own.
    private static func copySettings() {
        let defaults = UserDefaults.standard
        guard let id = Bundle.main.bundleIdentifier,
              defaults.persistentDomain(forName: id)?.isEmpty ?? true,
              let old = defaults.persistentDomain(forName: oldBundleID), !old.isEmpty else { return }
        defaults.setPersistentDomain(old, forName: id)
    }

    #if DEBUG
    /// `CopyPasta --check-migration`: runs moveHistory on throwaway folders and asserts
    /// nothing is lost, including copies still sitting in an uncheckpointed WAL.
    static func selfCheck() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("copypasta-migration-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func count(_ url: URL) -> Int64 {
            var db: OpaquePointer?, stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt); sqlite3_close(db) }
            guard sqlite3_open(url.path, &db) == SQLITE_OK,
                  sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM items", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
            return sqlite3_column_int64(stmt, 0)
        }
        /// A Pastey folder whose last rows exist only in the WAL (as after a crash).
        func makePastey(_ dir: URL, rows: Int) {
            let staging = root.appendingPathComponent("staging-\(UUID().uuidString)")
            try! fm.createDirectory(at: staging, withIntermediateDirectories: true)
            var db: OpaquePointer?
            sqlite3_open(staging.appendingPathComponent("pastey.db").path, &db)
            sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;" +
                         "CREATE TABLE items(id INTEGER PRIMARY KEY, t TEXT); CREATE TABLE boards(id INTEGER PRIMARY KEY);", nil, nil, nil)
            for i in 0..<rows { sqlite3_exec(db, "INSERT INTO items(t) VALUES ('clip \(i)')", nil, nil, nil) }
            try! fm.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
            for name in ["pastey.db", "pastey.db-wal", "pastey.db-shm"] {   // copied while still open
                try! fm.copyItem(at: staging.appendingPathComponent(name), to: dir.appendingPathComponent(name))
            }
            sqlite3_close(db)
            try! Data("png".utf8).write(to: dir.appendingPathComponent("images/a.png"))
            try! Data("log".utf8).write(to: dir.appendingPathComponent("pastey.log"))
        }

        // 1. Fresh install: everything moves, nothing lost.
        var old = root.appendingPathComponent("1/Pastey"), new = root.appendingPathComponent("1/CopyPasta")
        makePastey(old, rows: 25)
        assert(fm.fileExists(atPath: old.appendingPathComponent("pastey.db-wal").path))
        var quit = false
        moveHistory(from: old, to: new) { quit = true }
        assert(quit && !fm.fileExists(atPath: old.path))
        assert(count(new.appendingPathComponent("copypasta.db")) == 25, "rows lost")
        assert(fm.fileExists(atPath: new.appendingPathComponent("images/a.png").path))
        assert(fm.fileExists(atPath: new.appendingPathComponent("copypasta.log").path))

        // 2. CopyPasta already ran once with nothing in its history (but a key and a
        // dictation saved meanwhile): Pastey's history replaces the empty one, the rest stays.
        old = root.appendingPathComponent("2/Pastey"); new = root.appendingPathComponent("2/CopyPasta")
        makePastey(old, rows: 3)
        try! fm.createDirectory(at: new.appendingPathComponent("Credentials"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: new.appendingPathComponent("Dictation"), withIntermediateDirectories: true)
        try! Data("key".utf8).write(to: new.appendingPathComponent("Credentials/k.key"))
        try! Data("words".utf8).write(to: new.appendingPathComponent("Dictation/t.txt"))
        var db: OpaquePointer?
        sqlite3_open(new.appendingPathComponent("copypasta.db").path, &db)
        sqlite3_exec(db, "CREATE TABLE items(id INTEGER PRIMARY KEY); CREATE TABLE boards(id INTEGER PRIMARY KEY);", nil, nil, nil)
        sqlite3_close(db)
        moveHistory(from: old, to: new) {}
        assert(count(new.appendingPathComponent("copypasta.db")) == 3, "empty new history not replaced")
        assert(fm.fileExists(atPath: new.appendingPathComponent("Credentials/k.key").path), "key lost in merge")
        assert(fm.fileExists(atPath: new.appendingPathComponent("Dictation/t.txt").path), "dictation lost in merge")
        assert(fm.fileExists(atPath: new.appendingPathComponent("images/a.png").path), "Pastey images not merged")
        assert(!fm.fileExists(atPath: old.path))

        // 3. CopyPasta has its own history: leave both alone.
        old = root.appendingPathComponent("3/Pastey"); new = root.appendingPathComponent("3/CopyPasta")
        makePastey(old, rows: 2)
        try! fm.createDirectory(at: new, withIntermediateDirectories: true)
        sqlite3_open(new.appendingPathComponent("copypasta.db").path, &db)
        sqlite3_exec(db, "CREATE TABLE items(id INTEGER PRIMARY KEY); CREATE TABLE boards(id INTEGER PRIMARY KEY); INSERT INTO items DEFAULT VALUES;", nil, nil, nil)
        sqlite3_close(db)
        moveHistory(from: old, to: new) { assertionFailure("must not quit Pastey") }
        assert(count(new.appendingPathComponent("copypasta.db")) == 1 && fm.fileExists(atPath: old.path))

        print("migration check passed")
    }
    #endif
}
