"""The indexer's state file on the laptop (``state.sqlite`` in its own folder, never in Dropbox).

It holds, for every DWG and PDF seen, the size and modified time it was read at and what was read from it, so a
restart re-reads only files that changed, and a first scan that stops part way carries on where it stopped. Each
file's facts are committed as it is read (in small batches), so at most a batch is read again after a crash.
"""

from __future__ import annotations

import json
import sqlite3
import time
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS files (
  key TEXT PRIMARY KEY,
  path TEXT NOT NULL,
  kind TEXT NOT NULL,
  size INTEGER NOT NULL,
  mtime_ns INTEGER NOT NULL,
  online_only INTEGER NOT NULL,
  reader TEXT NOT NULL,
  facts TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS orphans (name TEXT PRIMARY KEY, since REAL NOT NULL);
CREATE TABLE IF NOT EXISTS thumbnails (name TEXT PRIMARY KEY, png BLOB NOT NULL);
"""


@dataclass
class Record:
    path: str
    kind: str
    size: int
    mtime_ns: int
    online_only: bool
    reader: str  # what read it: "unread" for an online-only file, else the reader's id ("pdfium-1", "accoreconsole-1")
    facts: dict


class State:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        # One thread uses it at a time; the watcher runs the indexer on its own thread in tests.
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.executescript(SCHEMA)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.pending = 0
        self.last_commit = time.monotonic()

    def close(self) -> None:
        if self.db is not None:
            self.db.commit()
            self.db.close()
            self.db = None

    def get(self, key: str) -> Record | None:
        row = self.db.execute(
            "SELECT path, kind, size, mtime_ns, online_only, reader, facts FROM files WHERE key = ?", (key,)
        ).fetchone()
        return _record(row) if row else None

    def put(self, key: str, record: Record) -> None:
        self.db.execute(
            "INSERT OR REPLACE INTO files VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (
                key, record.path, record.kind, record.size, record.mtime_ns, int(record.online_only), record.reader,
                json.dumps(record.facts, sort_keys=True),
            ),
        )
        self._maybe_commit()

    def delete(self, key: str) -> bool:
        gone = self.db.execute("DELETE FROM files WHERE key = ?", (key,)).rowcount > 0
        self._maybe_commit()
        return gone

    def delete_under(self, folder_key: str) -> int:
        prefix = folder_key.rstrip("/") + "/"
        gone = self.db.execute(
            "DELETE FROM files WHERE substr(key, 1, ?) = ?", (len(prefix), prefix)
        ).rowcount
        self._maybe_commit()
        return gone

    def all_keys(self) -> set[str]:
        return {k for (k,) in self.db.execute("SELECT key FROM files")}

    def records(self) -> Iterator[tuple[str, Record]]:
        for row in self.db.execute("SELECT key, path, kind, size, mtime_ns, online_only, reader, facts FROM files"):
            yield row[0], _record(row[1:])

    def count(self) -> int:
        return self.db.execute("SELECT count(*) FROM files").fetchone()[0]

    def meta(self, key: str, default: str | None = None) -> str | None:
        row = self.db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return row[0] if row else default

    def set_meta(self, key: str, value: str) -> None:
        self.db.execute("INSERT OR REPLACE INTO meta VALUES (?, ?)", (key, value))
        self._maybe_commit()

    def put_thumbnail(self, name: str, png: bytes) -> None:
        self.db.execute("INSERT OR IGNORE INTO thumbnails VALUES (?, ?)", (name, png))

    def thumbnail(self, name: str) -> bytes | None:
        row = self.db.execute("SELECT png FROM thumbnails WHERE name = ?", (name,)).fetchone()
        return row[0] if row else None

    def drop_thumbnails_except(self, names: set[str]) -> None:
        kept = self.db.execute("SELECT name FROM thumbnails").fetchall()
        self.db.executemany("DELETE FROM thumbnails WHERE name = ?", [(n,) for (n,) in kept if n not in names])

    def orphans(self) -> dict[str, float]:
        return dict(self.db.execute("SELECT name, since FROM orphans"))

    def set_orphans(self, orphans: dict[str, float]) -> None:
        self.db.execute("DELETE FROM orphans")
        self.db.executemany("INSERT INTO orphans VALUES (?, ?)", orphans.items())
        self.commit()

    def commit(self) -> None:
        self.db.commit()
        self.pending = 0
        self.last_commit = time.monotonic()

    def _maybe_commit(self) -> None:
        self.pending += 1
        if self.pending >= 50 or time.monotonic() - self.last_commit > 2:
            self.commit()


def _record(row) -> Record:
    path, kind, size, mtime_ns, online_only, reader, facts = row
    return Record(path, kind, size, mtime_ns, bool(online_only), reader, json.loads(facts))
