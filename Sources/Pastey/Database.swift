import AppKit
import SQLite3
import CryptoKit

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct ClipItem: Identifiable, Equatable {
    enum Kind: String {
        case text, link, image, file
    }

    let id: Int64
    let createdAt: Date
    let kind: Kind
    let plainText: String?
    let rtf: Data?
    let html: Data?
    let imagePath: String?
    let thumb: Data?
    let filePaths: [String]
    let sourceBundleID: String?
    let sourceAppName: String?
    let contentHash: String
    let charCount: Int
    let pixelW: Int
    let pixelH: Int

    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool { lhs.id == rhs.id }
}

struct Board: Identifiable, Equatable {
    let id: Int64
    var name: String
    var colorHex: String
}

/// What the clipboard watcher hands to the DB.
struct Capture {
    var kind: ClipItem.Kind
    var plainText: String?
    var rtf: Data?
    var html: Data?
    var imagePath: String?
    var thumb: Data?
    var filePaths: [String] = []
    var sourceBundleID: String?
    var sourceAppName: String?
    var contentHash: String
    var charCount: Int = 0
    var pixelW: Int = 0
    var pixelH: Int = 0
}

/// ponytail: single-connection SQLite on the main thread. Fine for a clipboard
/// manager's write rate; move to a queue if it ever isn't.
final class DB {
    static let shared = DB()

    static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pastey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let imagesDir: URL = {
        let dir = supportDir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var db: OpaquePointer?

    private init() {
        sqlite3_open(DB.supportDir.appendingPathComponent("pastey.db").path, &db)
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            kind TEXT NOT NULL,
            plain_text TEXT,
            rtf BLOB,
            html BLOB,
            image_path TEXT,
            thumb BLOB,
            file_paths TEXT,
            source_bundle_id TEXT,
            source_app_name TEXT,
            content_hash TEXT UNIQUE NOT NULL,
            char_count INTEGER NOT NULL DEFAULT 0,
            pixel_w INTEGER NOT NULL DEFAULT 0,
            pixel_h INTEGER NOT NULL DEFAULT 0
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_items_created ON items(created_at DESC)")
        exec("""
        CREATE TABLE IF NOT EXISTS boards (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            color TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0
        )
        """)
        // Migration from v0.1 schema; errors (column already exists) are ignored.
        exec("ALTER TABLE items ADD COLUMN board_id INTEGER")
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Bind/read helpers

    private func bind(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, idx) }
    }

    private func bind(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Data?) {
        if let value {
            _ = value.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(value.count), SQLITE_TRANSIENT) }
        } else { sqlite3_bind_null(stmt, idx) }
    }

    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        sqlite3_column_text(stmt, idx).map { String(cString: $0) }
    }

    private func columnData(_ stmt: OpaquePointer?, _ idx: Int32) -> Data? {
        guard let ptr = sqlite3_column_blob(stmt, idx) else { return nil }
        return Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, idx)))
    }

    // MARK: - Operations

    /// Insert, or if the same content was copied before, bump it to the top.
    func upsert(_ c: Capture, boardID: Int64? = nil) {
        let sql = """
        INSERT INTO items (created_at, kind, plain_text, rtf, html, image_path, thumb, file_paths,
                           source_bundle_id, source_app_name, content_hash, char_count, pixel_w, pixel_h, board_id)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(content_hash) DO UPDATE SET
            created_at = excluded.created_at,
            source_bundle_id = excluded.source_bundle_id,
            source_app_name = excluded.source_app_name
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        bind(stmt, 2, c.kind.rawValue)
        bind(stmt, 3, c.plainText)
        bind(stmt, 4, c.rtf)
        bind(stmt, 5, c.html)
        bind(stmt, 6, c.imagePath)
        bind(stmt, 7, c.thumb)
        bind(stmt, 8, c.filePaths.isEmpty ? nil : c.filePaths.joined(separator: "\n"))
        bind(stmt, 9, c.sourceBundleID)
        bind(stmt, 10, c.sourceAppName)
        bind(stmt, 11, c.contentHash)
        sqlite3_bind_int64(stmt, 12, Int64(c.charCount))
        sqlite3_bind_int64(stmt, 13, Int64(c.pixelW))
        sqlite3_bind_int64(stmt, 14, Int64(c.pixelH))
        if let boardID { sqlite3_bind_int64(stmt, 15, boardID) } else { sqlite3_bind_null(stmt, 15) }
        sqlite3_step(stmt)
    }

    /// Replace an item's text (plain only — drops any rtf/html richness). Recomputes
    /// the content hash so future dedup matches the new text; if that new hash would
    /// collide with another item (content_hash is UNIQUE), keeps the old hash so the
    /// edit still saves.
    func updateText(_ id: Int64, to text: String) {
        if !writeText(id, text: text, hash: sha256(Data(text.utf8))) {
            writeText(id, text: text, hash: nil)
        }
    }

    @discardableResult
    private func writeText(_ id: Int64, text: String, hash: String?) -> Bool {
        let sql = hash == nil
            ? "UPDATE items SET plain_text = ?, char_count = ?, rtf = NULL, html = NULL WHERE id = ?"
            : "UPDATE items SET plain_text = ?, char_count = ?, rtf = NULL, html = NULL, content_hash = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, text)
        sqlite3_bind_int64(stmt, 2, Int64(text.count))
        if let hash {
            bind(stmt, 3, hash)
            sqlite3_bind_int64(stmt, 4, id)
        } else {
            sqlite3_bind_int64(stmt, 3, id)
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// boardID nil = the rolling clipboard history; otherwise items pinned to that board.
    func recent(boardID: Int64? = nil, limit: Int = 200) -> [ClipItem] {
        let sql = """
        SELECT id, created_at, kind, plain_text, rtf, html, image_path, thumb, file_paths,
               source_bundle_id, source_app_name, content_hash, char_count, pixel_w, pixel_h
        FROM items WHERE board_id \(boardID == nil ? "IS NULL" : "= ?") ORDER BY created_at DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        if let boardID {
            sqlite3_bind_int64(stmt, idx, boardID)
            idx += 1
        }
        sqlite3_bind_int64(stmt, idx, Int64(limit))
        var items: [ClipItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(ClipItem(
                id: sqlite3_column_int64(stmt, 0),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                kind: ClipItem.Kind(rawValue: columnText(stmt, 2) ?? "text") ?? .text,
                plainText: columnText(stmt, 3),
                rtf: columnData(stmt, 4),
                html: columnData(stmt, 5),
                imagePath: columnText(stmt, 6),
                thumb: columnData(stmt, 7),
                filePaths: columnText(stmt, 8).map { $0.components(separatedBy: "\n") } ?? [],
                sourceBundleID: columnText(stmt, 9),
                sourceAppName: columnText(stmt, 10),
                contentHash: columnText(stmt, 11) ?? "",
                charCount: Int(sqlite3_column_int64(stmt, 12)),
                pixelW: Int(sqlite3_column_int64(stmt, 13)),
                pixelH: Int(sqlite3_column_int64(stmt, 14))
            ))
        }
        return items
    }

    func delete(_ item: ClipItem) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM items WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, item.id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        // The same image file can back both a history row and pinned copies.
        if let path = item.imagePath { removeImageIfOrphan(path) }
    }

    /// Clears the rolling history; pinned board items survive.
    func clearAll() {
        exec("DELETE FROM items WHERE board_id IS NULL")
        pruneOrphanImages()
    }

    /// Keep at most `max` history items; boards are exempt.
    func trim(max: Int = 10000) {
        let sql = "SELECT id, image_path FROM items WHERE board_id IS NULL ORDER BY created_at DESC LIMIT -1 OFFSET ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, Int64(max))
        var ids: [Int64] = []
        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
            if let path = columnText(stmt, 1) { paths.append(path) }
        }
        sqlite3_finalize(stmt)
        guard !ids.isEmpty else { return }
        exec("DELETE FROM items WHERE id IN (\(ids.map(String.init).joined(separator: ",")))")
        paths.forEach(removeImageIfOrphan)
    }

    /// Delete history items older than `interval` seconds; boards exempt.
    /// `interval == .infinity` (Keep History = Forever) is a no-op.
    func pruneHistory(olderThan interval: TimeInterval) {
        guard interval.isFinite else { return }
        let cutoff = Date().timeIntervalSince1970 - interval
        let sql = "SELECT id, image_path FROM items WHERE board_id IS NULL AND created_at < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, cutoff)
        var ids: [Int64] = []
        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
            if let path = columnText(stmt, 1) { paths.append(path) }
        }
        sqlite3_finalize(stmt)
        guard !ids.isEmpty else { return }
        exec("DELETE FROM items WHERE id IN (\(ids.map(String.init).joined(separator: ",")))")
        paths.forEach(removeImageIfOrphan)
    }

    private func removeImageIfOrphan(_ path: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM items WHERE image_path = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, path)
        if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int64(stmt, 0) == 0 {
            try? FileManager.default.removeItem(at: DB.imagesDir.appendingPathComponent(path))
        }
    }

    private func pruneOrphanImages() {
        var referenced = Set<String>()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT DISTINCT image_path FROM items WHERE image_path IS NOT NULL", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let path = columnText(stmt, 0) { referenced.insert(path) }
            }
        }
        sqlite3_finalize(stmt)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: DB.imagesDir.path)) ?? []
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: DB.imagesDir.appendingPathComponent(file))
        }
    }

    /// One-time: rebuild every stored thumbnail from its full-res PNG on disk at
    /// the new higher resolution. Guarded so it runs once per thumbnail version.
    func regenerateThumbnailsIfNeeded() {
        let key = "thumbnailVersion"
        guard UserDefaults.standard.integer(forKey: key) < 2 else { return }

        var rows: [(Int64, String)] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, image_path FROM items WHERE image_path IS NOT NULL", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let path = columnText(stmt, 1) { rows.append((sqlite3_column_int64(stmt, 0), path)) }
            }
        }
        sqlite3_finalize(stmt)

        for (id, path) in rows {
            guard let data = try? Data(contentsOf: DB.imagesDir.appendingPathComponent(path)),
                  let thumb = makeThumbnail(data) else { continue }
            var up: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE items SET thumb = ? WHERE id = ?", -1, &up, nil) == SQLITE_OK {
                bind(up, 1, thumb)
                sqlite3_bind_int64(up, 2, id)
                sqlite3_step(up)
            }
            sqlite3_finalize(up)
        }
        UserDefaults.standard.set(2, forKey: key)
        plog("regenerated \(rows.count) thumbnails")
    }

    // MARK: - Boards

    func boards() -> [Board] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, name, color FROM boards ORDER BY sort_order, id", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [Board] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(Board(
                id: sqlite3_column_int64(stmt, 0),
                name: columnText(stmt, 1) ?? "Untitled",
                colorHex: columnText(stmt, 2) ?? "#4D8DFF"
            ))
        }
        return result
    }

    @discardableResult
    func createBoard(name: String, colorHex: String) -> Board {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO boards (name, color, sort_order) VALUES (?, ?, (SELECT IFNULL(MAX(sort_order), 0) + 1 FROM boards))"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            bind(stmt, 1, name)
            bind(stmt, 2, colorHex)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        return Board(id: sqlite3_last_insert_rowid(db), name: name, colorHex: colorHex)
    }

    func renameBoard(_ id: Int64, to name: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE boards SET name = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, name)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    func recolorBoard(_ id: Int64, to colorHex: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE boards SET color = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, colorHex)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    func deleteBoard(_ id: Int64) {
        exec("DELETE FROM items WHERE board_id = \(id)")
        exec("DELETE FROM boards WHERE id = \(id)")
        pruneOrphanImages()
    }

    /// Pinning copies the item into the board; the history row keeps rolling independently.
    func pin(_ item: ClipItem, to boardID: Int64) {
        let base = item.contentHash.components(separatedBy: ":b").first ?? item.contentHash
        let copy = Capture(
            kind: item.kind,
            plainText: item.plainText,
            rtf: item.rtf,
            html: item.html,
            imagePath: item.imagePath,
            thumb: item.thumb,
            filePaths: item.filePaths,
            sourceBundleID: item.sourceBundleID,
            sourceAppName: item.sourceAppName,
            contentHash: base + ":b\(boardID)", // per-board hash → re-pin dedups within the board
            charCount: item.charCount,
            pixelW: item.pixelW,
            pixelH: item.pixelH
        )
        upsert(copy, boardID: boardID)
    }

    // MARK: - Pasteboard write-back

    func copyToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text, .link:
            if let s = item.plainText { pb.setString(s, forType: .string) }
            if let rtf = item.rtf { pb.setData(rtf, forType: .rtf) }
            if let html = item.html { pb.setData(html, forType: .html) }
        case .image:
            if let path = item.imagePath,
               let data = try? Data(contentsOf: DB.imagesDir.appendingPathComponent(path)) {
                pb.setData(data, forType: .png)
                if let tiff = NSImage(data: data)?.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
            }
        case .file:
            let urls = item.filePaths.map { NSURL(fileURLWithPath: $0) }
            if !urls.isEmpty { pb.writeObjects(urls) }
        }
    }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Lightweight diagnostic log at ~/Library/Application Support/Pastey/pastey.log.
func plog(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date()))  \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = DB.supportDir.appendingPathComponent("pastey.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}
