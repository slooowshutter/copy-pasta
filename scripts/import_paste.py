#!/usr/bin/env python3
"""One-off importer: real Paste.app (Setapp) Core Data store -> Pastey SQLite.

Imports text/link items only. Paste stores the full payload encrypted; the
cleartext JSON *preview* caps text at 500 chars, so longer items import
truncated (reported at the end). Images live in the encrypted blob and are
skipped. Idempotent: re-running dedupes on content_hash.

Usage: python3 import_paste.py [--history-limit N]
"""
import sqlite3, json, hashlib, os, sys, plistlib

COCOA_EPOCH = 978307200  # 2001-01-01 -> unix
PASTE_SRC = "/tmp/paste-import.sqlite"  # safe .backup copy of Paste's db.sqlite
PASTEY_DB = os.path.expanduser("~/Library/Application Support/Pastey/pastey.db")

# Paste pinboards to import (name -> Paste list ZIDENTIFIER prefix is irrelevant; match by name)
WANTED_BOARDS = ["Prompts", "Code", "Useful Links"]
HISTORY_LIMIT = 10000  # effectively "all text history"; overridable via --history-limit


def h(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def color_hex(code):
    """Paste colorCode int -> #RRGGBB (drops alpha byte if present)."""
    return "#%06X" % (code & 0xFFFFFF)


def is_link(t):
    t = t.strip()
    return (" " not in t and "\n" not in t
            and (t.startswith("http://") or t.startswith("https://")))


def preview_text(blob):
    """Return (text, full_length) from a Paste preview blob, or None if not text."""
    if not blob:
        return None
    b = bytes(blob)
    if b[:1] != b"{":
        return None  # bplist == image, or other
    try:
        j = json.loads(b.decode("utf-8", "replace"))
    except Exception:
        return None
    if j.get("type") != "text" or not isinstance(j.get("text"), str):
        return None
    return j["text"], (j.get("textLength") or len(j["text"]))


def main():
    global HISTORY_LIMIT
    if "--history-limit" in sys.argv:
        HISTORY_LIMIT = int(sys.argv[sys.argv.index("--history-limit") + 1])

    src = sqlite3.connect(PASTE_SRC)
    dst = sqlite3.connect(PASTEY_DB)

    # source-app lookup
    apps = {pk: (name, bid) for pk, name, bid in
            src.execute("SELECT Z_PK, ZNAME, ZBUNDLEIDENTIFIER FROM ZAPPLICATIONENTITY")}

    stats = {"boards": 0, "board_items": 0, "history": 0,
             "truncated": 0, "images_skipped": 0, "noprev_skipped": 0, "dup": 0}

    def insert_item(text, full_len, ts, src_app_pk, board_id):
        name, bid = apps.get(src_app_pk, (None, None))
        kind = "link" if is_link(text) else "text"
        base = h(text)
        content_hash = base + (f":b{board_id}" if board_id else "")
        try:
            dst.execute(
                """INSERT INTO items (created_at, kind, plain_text, content_hash,
                                      source_bundle_id, source_app_name, char_count, board_id)
                   VALUES (?,?,?,?,?,?,?,?)""",
                (ts, kind, text, content_hash, bid, name, len(text), board_id))
            if full_len > 500:
                stats["truncated"] += 1
            return True
        except sqlite3.IntegrityError:
            stats["dup"] += 1
            return False

    # --- pinboards ---
    board_pk_by_name = {}
    for pk, name, attr in src.execute(
            "SELECT Z_PK, ZNAME, ZRAWATTRIBUTES FROM ZLISTENTITY WHERE ZRAWTYPE=2"):
        if name not in WANTED_BOARDS:
            continue
        board_pk_by_name[name] = pk
        chex = "#4D8DFF"
        if attr:
            try:
                chex = color_hex(json.loads(bytes(attr).decode("utf-8", "replace"))["colorCode"])
            except Exception:
                pass
        row = dst.execute("SELECT id FROM boards WHERE name=?", (name,)).fetchone()
        if row:
            bid = row[0]
            dst.execute("UPDATE boards SET color=? WHERE id=?", (chex, bid))
        else:
            dst.execute(
                "INSERT INTO boards (name, color, sort_order) VALUES (?,?,(SELECT IFNULL(MAX(sort_order),0)+1 FROM boards))",
                (name, chex))
            bid = dst.execute("SELECT last_insert_rowid()").fetchone()[0]
            stats["boards"] += 1
        board_pk_by_name[name] = (pk, bid)

    for name, (paste_pk, bid) in board_pk_by_name.items():
        for prev, ts_c, ts_t, src_app in src.execute(
                "SELECT ZRAWPREVIEW, ZCREATEDAT, ZTIMESTAMP, ZSOURCEAPPLICATION "
                "FROM ZITEMENTITY WHERE ZLIST=? ORDER BY ZDISPLAYORDERINPINBOARD", (paste_pk,)):
            pt = preview_text(prev)
            if pt is None:
                stats["images_skipped"] += 1 if prev else 0
                stats["noprev_skipped"] += 0 if prev else 1
                continue
            text, full = pt
            ts = (ts_t or ts_c or 0) + COCOA_EPOCH
            if insert_item(text, full, ts, src_app, bid):
                stats["board_items"] += 1

    # --- history (ZLIST IS NULL), newest first ---
    for prev, ts_c, ts_t, src_app in src.execute(
            "SELECT ZRAWPREVIEW, ZCREATEDAT, ZTIMESTAMP, ZSOURCEAPPLICATION "
            "FROM ZITEMENTITY WHERE ZLIST IS NULL "
            "ORDER BY COALESCE(ZTIMESTAMP, ZCREATEDAT) DESC LIMIT ?", (HISTORY_LIMIT,)):
        pt = preview_text(prev)
        if pt is None:
            if prev:
                stats["images_skipped"] += 1
            else:
                stats["noprev_skipped"] += 1
            continue
        text, full = pt
        ts = (ts_t or ts_c or 0) + COCOA_EPOCH
        if insert_item(text, full, ts, src_app, None):
            stats["history"] += 1

    dst.commit()
    dst.close()
    src.close()

    print("Import complete:")
    for k, v in stats.items():
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
