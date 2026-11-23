import AppKit
import Compression
import SQLite3

/// `CopyPasta import-paste`: brings the history and pinboards of Paste (Setapp's Paste 7)
/// across, whole: rich text, images, files and links, from Paste's own copy of what was on
/// the clipboard, each item going through the same code as a live copy. Pinboards keep
/// their names, colors and order. Run with CopyPasta quit; running it again adds only
/// what's new.
enum PasteImport {
    static let store = DB.supportDir.deletingLastPathComponent()
        .appendingPathComponent("com.wiheads.paste-setapp/db.sqlite")
    private static var external: URL {
        store.deletingLastPathComponent().appendingPathComponent(".db_SUPPORT/_EXTERNAL_DATA")
    }

    static func run() -> Int32 {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.marclamy.copypasta")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard others.isEmpty else {
            print("Quit CopyPasta first (menu bar icon › Quit CopyPasta), then run this again.")
            return 1
        }
        var paste: OpaquePointer?
        // Read-only: Paste may be running; nothing of its is changed.
        guard FileManager.default.fileExists(atPath: store.path),
              sqlite3_open_v2("file:\(store.path)?mode=ro", &paste, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else {
            print("Paste's data isn't at \(store.path).")
            return 1
        }
        defer { sqlite3_close(paste) }

        var apps: [Int64: (name: String?, bundleID: String?)] = [:]
        query(paste, "SELECT Z_PK, ZNAME, ZBUNDLEIDENTIFIER FROM ZAPPLICATIONENTITY") { row in
            apps[row.int(0)] = (row.text(1), row.text(2))
        }

        // Pinboards: each Paste one onto the CopyPasta board of the same name, else a new one.
        var boardFor: [Int64: Int64] = [:]
        var unclaimed = DB.shared.boards()
        query(paste, "SELECT Z_PK, ZNAME, ZRAWATTRIBUTES FROM ZLISTENTITY WHERE ZRAWTYPE = 2 ORDER BY Z_PK") { row in
            let name = row.text(1) ?? "Untitled"
            if let i = unclaimed.firstIndex(where: { $0.name == name }) {
                boardFor[row.int(0)] = unclaimed.remove(at: i).id
            } else {
                let attributes = row.data(2).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let code = (attributes?["colorCode"] as? NSNumber)?.int64Value
                let color = code.map { String(format: "#%06X", $0 & 0xFFFFFF) } ?? Board.presetColors[boardFor.count % Board.presetColors.count]
                boardFor[row.int(0)] = DB.shared.createBoard(name: name, colorHex: color).id
                print("New pinboard: \(name)")
            }
        }

        struct Row { let list: Int64?; let app: Int64?; let date: Date; let order: Int64; let payload: Data?; let preview: Data? }
        var rows: [Row] = []
        query(paste, """
            SELECT i.ZLIST, i.ZSOURCEAPPLICATION, COALESCE(i.ZTIMESTAMP, i.ZCREATEDAT, 0), i.ZDISPLAYORDERINPINBOARD,
                   d.ZRAWPASTEBOARDITEMS, i.ZRAWPREVIEW
            FROM ZITEMENTITY i LEFT JOIN ZITEMDATAENTITY d ON d.Z_PK = i.ZDATA
            """) { row in
            rows.append(Row(list: row.isNull(0) ? nil : row.int(0), app: row.isNull(1) ? nil : row.int(1),
                            date: Date(timeIntervalSinceReferenceDate: row.double(2)), order: row.int(3),
                            payload: row.data(4), preview: row.data(5)))
        }
        // A pinboard's order is the one arranged in Paste; CopyPasta shows a board newest
        // first: its items' dates, newest first, go to them in Paste's order.
        var dates: [Int: Date] = [:]
        for list in Set(rows.compactMap(\.list)) {
            let members = rows.indices.filter { rows[$0].list == list }
            let order = members.sorted { rows[$0].order < rows[$1].order }
            let newestFirst = members.map { rows[$0].date }.sorted(by: >)
            for (i, row) in order.enumerated() { dates[row] = newestFirst[i] }
        }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.marclamy.copypasta.import"))
        defer { pasteboard.releaseGlobally() }
        var added = 0, skipped = 0, fromPreview = 0
        DB.shared.exec("BEGIN")
        for (n, row) in rows.enumerated() {
            if n > 0, n.isMultiple(of: 250) { print("  \(n) of \(rows.count)…") }
            let boardID = row.list.flatMap { boardFor[$0] }
            if row.list != nil, boardID == nil { continue }   // the Clipboard list itself, or one we don't know
            var items = row.payload.flatMap(Self.pasteboardItems) ?? []
            if items.isEmpty, let text = row.preview.flatMap(Self.previewText) {   // payload unreadable
                items = [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]]
                fromPreview += 1
            }
            guard fill(pasteboard, with: items), !ClipboardWatcher.isPrivate(pasteboard.types ?? []),
                  var capture = ClipboardWatcher.capture(from: pasteboard) else { skipped += 1; continue }
            let app = row.app.flatMap { apps[$0] }
            capture.sourceBundleID = app?.bundleID
            capture.sourceAppName = app?.name
            if let boardID { capture.contentHash += ":b\(boardID)" }   // as pinning does
            DB.shared.upsert(capture, boardID: boardID, at: dates[n] ?? row.date)
            added += 1
        }
        DB.shared.exec("COMMIT")
        print("Imported \(added) items from Paste (\(boardFor.count) pinboards).")
        if fromPreview > 0 { print("\(fromPreview) came from Paste's preview: their full copy couldn't be read, long ones are cut at 500 characters.") }
        if skipped > 0 { print("\(skipped) skipped: empty, or marked private by a password manager.") }
        return 0
    }

    /// Puts an item's flavors on the pasteboard. A picture only in JPEG or HEIC goes where a
    /// copy's reader looks (it converts any image format), and a file that's gone (a
    /// screenshot's temporary file) is left out when its picture is there instead.
    private static func fill(_ pasteboard: NSPasteboard, with items: [[String: Data]]) -> Bool {
        pasteboard.clearContents()
        let objects = items.map { flavors -> NSPasteboardItem in
            var flavors = flavors
            if flavors["public.png"] == nil, flavors["public.tiff"] == nil {
                flavors["public.tiff"] = flavors["public.jpeg"] ?? flavors["public.heic"]
            }
            if let url = flavors["public.file-url"].flatMap({ String(data: $0, encoding: .utf8) }).flatMap(URL.init(string:)),
               !FileManager.default.fileExists(atPath: url.path), flavors["public.png"] ?? flavors["public.tiff"] != nil {
                flavors["public.file-url"] = nil
            }
            let item = NSPasteboardItem()
            for (type, data) in flavors { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        return !objects.isEmpty && pasteboard.writeObjects(objects)
    }

    // MARK: Paste's storage

    /// ZRAWPASTEBOARDITEMS: one dictionary of flavors (type → data) per pasteboard item.
    static func pasteboardItems(_ value: Data) -> [[String: Data]]? {
        guard let list = plist(value) as? [[String: Any]] else { return nil }
        return list.compactMap { $0["dataByType"] as? [String: Data] }
    }

    /// ZRAWPREVIEW of a text item: its first 500 characters.
    static func previewText(_ value: Data) -> String? {
        guard let preview = plist(value) as? [String: Any], preview["type"] as? String == "text" else { return nil }
        return preview["text"] as? String
    }

    /// A Core Data binary value: 0x01 and the bytes, or 0x02 and the name of a file holding
    /// them. Paste compresses most of them (LZFSE, sometimes zlib).
    static func plist(_ value: Data) -> Any? {
        var bytes = value
        if bytes.first == 2 {
            let name = String(decoding: bytes.dropFirst().prefix { $0 != 0 }, as: UTF8.self)
            guard let file = try? Data(contentsOf: external.appendingPathComponent(name)) else { return nil }
            bytes = file
        }
        if bytes.first == 1 { bytes = bytes.dropFirst() }
        let magic = Data("bplist00".utf8)
        if !bytes.starts(with: magic) {
            guard let plain = decompress(Data(bytes)), plain.starts(with: magic) else { return nil }
            bytes = plain
        }
        return try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil)
    }

    private static func decompress(_ data: Data) -> Data? {
        for algorithm in [COMPRESSION_LZFSE, COMPRESSION_ZLIB, COMPRESSION_LZ4, COMPRESSION_LZMA] {
            var capacity = max(data.count * 30, 1 << 20)
            while capacity <= 1 << 31 {
                var out = Data(count: capacity)
                let n = out.withUnsafeMutableBytes { dst in
                    data.withUnsafeBytes { src in
                        compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                                  src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, algorithm)
                    }
                }
                guard n > 0 else { break }   // not this algorithm
                if n < capacity { return out.prefix(n) }
                capacity *= 4   // filled the buffer: it may not all have fit
            }
        }
        return nil
    }

    // MARK: SQLite

    private struct Columns {
        let stmt: OpaquePointer?
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        func data(_ i: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }

    private static func query(_ db: OpaquePointer?, _ sql: String, _ each: (Columns) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { each(Columns(stmt: stmt)) }
    }
}
