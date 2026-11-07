"""The laptop indexer's work: scan the Dropbox folder, read what changed, and publish the drawing index.

A file is read only when its size, modified time or online-only state differs from the state file's, or its reader
changed (AutoCAD installed since). An online-only file is never opened in the Dropbox folder, since opening it makes
Dropbox download it there: it is downloaded through the Dropbox API to the scratch folder on the external drive, read
there and the copy deleted (scratch.py). While that can't happen (no drive, no sign-in) it is listed unread.

The scan and the watcher share one collector (``_gather``): it lists folders and looks up paths, drops from the
state file what is gone (never what sits in a folder that could not be listed), and returns what to read, one entry per
path. One work queue (``_work``) reads it, PDFs first, and takes the watcher's newest changes between files, ahead of
the rest, so a save is indexed within seconds even during a scan or a large copy.
"""

from __future__ import annotations

import json
import logging
import time
from collections import deque
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path

from vellum_indexer import dwg as dwg_module
from vellum_indexer import fields, files
from vellum_indexer import pdf as pdf_module
from vellum_indexer.dropbox_api import DropboxError
from vellum_indexer.index import IndexWriter, build_entries, content_name
from vellum_indexer.projects import ProjectFinder
from vellum_indexer.scratch import Downloader, Unavailable
from vellum_indexer.state import Record, State

log = logging.getLogger("vellum_indexer")

PDF_READER_ID = "pdfium-1"
UNREAD = "unread"
INDEX_FOLDER = ("Vellum", "Index")


@dataclass
class Counters:
    stat_files: int = 0
    pdfs_read: int = 0
    dwgs_read: int = 0
    online_only_listed: int = 0
    downloaded: int = 0
    thumbnails_made: int = 0
    removed: int = 0

    @property
    def files_read(self) -> int:
        return self.pdfs_read + self.dwgs_read


class Indexer:
    def __init__(
        self,
        root: Path,
        state: State,
        *,
        rules: files.SkipRules | None = None,
        projects: ProjectFinder | None = None,
        dwg_reader: dwg_module.TitleBlockReader | None = None,
        read_pdf: Callable[[Path], pdf_module.PdfFacts] = pdf_module.read_pdf,
        read_preview: Callable[[Path], bytes | None] = dwg_module.read_preview,
        attributes: files.AttributeReader = files.default_attributes,
        tags: fields.TagMap | None = None,
        progress_seconds: float = 30.0,
        publish_every_seconds: float = 600.0,
        downloader: Downloader | None = None,
    ):
        self.root = root
        self.state = state
        self.rules = rules or files.SkipRules()
        self.projects = projects or ProjectFinder()
        self.dwg_reader = dwg_reader or dwg_module.NoReader()
        self.read_pdf = read_pdf
        self.read_preview = read_preview
        self.attributes = attributes
        self.tags = tags or fields.TagMap()
        self.progress_seconds = progress_seconds
        self.publish_every_seconds = publish_every_seconds
        self.index_folder = root.joinpath(*INDEX_FOLDER)
        # Set by the watcher: gives a batch of (paths, folders) when one is due, else None.
        self.poll_changes: Callable[[], tuple[set[str], set[str]] | None] | None = None
        self.writer = IndexWriter(self.index_folder)
        self.counters = Counters()
        self.downloader = downloader
        if downloader is not None:
            downloader.clean()  # a copy a crash left behind

    # --- Reading ---

    def _reader_id(self, kind: str) -> str:
        return PDF_READER_ID if kind == "pdf" else self.dwg_reader.id

    def needs_read(self, facts: files.FileFacts) -> bool:
        record = self.state.get(files.key(facts.path))
        if record is None:
            return True
        if (record.size, record.mtime_ns, record.online_only) != (facts.size, facts.mtime_ns, facts.online_only):
            return True
        if record.path != facts.path:  # renamed in case only
            return True
        if record.reader == UNREAD:
            return facts.online_only and self._can_download(facts.size)
        return record.reader != self._reader_id(record.kind)

    def _can_download(self, size: int = 0) -> bool:
        return self.downloader is not None and self.downloader.available(size)

    def take(self, facts: files.FileFacts) -> None:
        """Read one file and keep what was read. An online-only file is read from a downloaded copy, or listed
        unread when it can't be downloaded now."""
        kind = files.kind_of(facts.path)
        key = files.key(facts.path)
        old = self.state.get(key)
        if (old is not None and old.path == facts.path and old.reader == self._reader_id(kind)
                and (old.size, old.mtime_ns) == (facts.size, facts.mtime_ns)):
            # Only made online-only (or made local again) with nothing changed: what was read still holds, and
            # nothing is downloaded or read again.
            self.state.put(key, Record(facts.path, kind, facts.size, facts.mtime_ns, facts.online_only, old.reader,
                                       old.facts))
            return
        copy = None
        if facts.online_only:
            if self.downloader is None:
                self._unread(key, facts, kind)
                return
            try:
                copy = self.downloader.fetch(facts.path, facts.size)
            except Unavailable:
                self._unread(key, facts, kind)
                return
            except DropboxError as error:
                log.warning("Could not download %s, to try again later: %s", facts.path, error)
                self._unread(key, facts, kind)
                return
            self.counters.downloaded += 1
            local = copy
        else:
            local = files.local_path(self.root, facts.path)
        try:
            read = self._read(kind, local)
        except OSError as error:
            # Locked or vanished part way (AutoCAD saving it, Dropbox syncing it): keep what was known and try
            # again with the next change or scan.
            log.info("Could not open %s yet: %s", local, error)
            return
        finally:
            if copy is not None:
                Downloader.done(copy)
        reader = self._reader_id(kind)
        if kind == "dwg" and "error" in read:
            reader += "-failed"  # read again at the next full scan, in case AutoCAD failed for a moment
        self.state.put(key, Record(facts.path, kind, facts.size, facts.mtime_ns, facts.online_only, reader, read))

    def _unread(self, key: str, facts: files.FileFacts, kind: str) -> None:
        self.counters.online_only_listed += 1
        old = self.state.get(key)
        if old is not None and old.reader != UNREAD and (old.size, old.mtime_ns) == (facts.size, facts.mtime_ns):
            # Freed up to online-only with nothing changed: what was read still holds.
            self.state.put(key, Record(facts.path, kind, facts.size, facts.mtime_ns, True, old.reader, old.facts))
            return
        self.state.put(key, Record(facts.path, kind, facts.size, facts.mtime_ns, True, UNREAD, {}))

    def _read(self, kind: str, local: Path) -> dict:
        if kind == "pdf":
            self.counters.pdfs_read += 1
            try:
                facts = self.read_pdf(local)
            except OSError:
                raise
            except Exception as error:  # noqa: BLE001 - a damaged PDF is listed with nothing read
                log.warning("Could not read %s: %s", local, error)
                return {"error": str(error)[:200]}
            out = {
                "contentHash": facts.content_hash,
                "pages": facts.pages,
                "paperInches": list(facts.paper_inches) if facts.paper_inches else None,
                "metaTitle": facts.meta_title,
                "metaCreator": facts.meta_creator,
                "text": fields.from_pdf_text(facts.text).as_dict(),
                "thumbnail": self._keep_thumbnail(facts.thumbnail_png),
            }
            return out
        self.counters.dwgs_read += 1
        if not local.is_file():
            raise FileNotFoundError(local)
        out: dict = {"thumbnail": self._keep_thumbnail(self.read_preview(local))}
        try:
            inserts = self.dwg_reader.read(local)
            out["sheets"] = [sheet.as_dict() for sheet in fields.sheets_from_attributes(inserts, self.tags)]
        except Exception as error:  # noqa: BLE001 - AutoCAD failing on one drawing never stops the scan
            log.warning("Could not read the title block of %s: %s", local, error)
            out["error"] = str(error)[:200]
        return out

    def _keep_thumbnail(self, png: bytes | None) -> str | None:
        if not png:
            return None
        name = content_name(png, ".png")
        if self.state.thumbnail(name) is None:
            self.counters.thumbnails_made += 1
            self.state.put_thumbnail(name, png)
        return name

    # --- Scanning ---

    def scan(self) -> None:
        """Rescan all of Dropbox: list it, read what changed, drop what is gone, publish."""
        started = time.monotonic()
        to_read = self._gather({"/"}, set())
        log.info("Listed %d drawings and PDFs in %.1f s; %d to read", self.counters.stat_files,
                 time.monotonic() - started, len(to_read))
        self._work(to_read)
        self.publish()
        log.info("Scan done in %.1f s", time.monotonic() - started)

    def update(self, paths: Iterable[str], folders: Iterable[str] = ()) -> set[str]:
        """What the watcher saw: Dropbox paths of files changed, made or deleted, and of folders made, moved in or
        deleted. Reads only those, then publishes. Returns the keys of the files it read."""
        read = self._work(self._gather(set(folders), set(paths)))
        self.publish()
        return read

    def retry_unread(self) -> set[str]:
        """Online-only files listed unread, read now if they can be downloaded (the drive is back, signed in)."""
        if not self._can_download():
            return set()
        waiting = {r.path for _, r in self.state.records() if r.reader == UNREAD}
        return self.update(waiting) if waiting else set()

    def _gather(self, folders: set[str], paths: set[str]) -> dict[str, files.FileFacts]:
        """The one collector for the scan and the watcher: walk the folders, look up the paths, drop from the state
        file what is gone, and return what to read, one entry per path (a path met twice in a batch, as a folder copy
        reports it, is read once). Nothing under a folder that could not be listed is dropped."""
        to_read: dict[str, files.FileFacts] = {}
        unlisted: list[str] = []

        def failed(path: Path, error: OSError) -> None:
            log.warning("Could not list %s: %s", path, error)
            unlisted.append(files.key(files.dropbox_path(self.root, path)).rstrip("/") + "/")

        def kept(key: str) -> bool:
            return any(key.startswith(u) for u in unlisted)

        for folder in sorted(folders):
            if folder != "/" and self.rules.skips_folder(folder):
                continue
            where = files.folder_state(self.root, folder)
            prefix = "" if folder == "/" else files.key(folder).rstrip("/") + "/"
            if where == "unknown":
                continue  # neither listed nor known to be gone: keep everything, look again later
            present: set[str] = set()
            if where == "folder":
                for facts in files.walk(self.root, self.rules, start=folder, attributes=self.attributes,
                                        on_error=failed):
                    self.counters.stat_files += 1
                    k = files.key(facts.path)
                    present.add(k)
                    if self.needs_read(facts):
                        to_read[k] = facts
            for k in [k for k in self.state.all_keys() if k.startswith(prefix) and k not in present and not kept(k)]:
                self.state.delete(k)
                to_read.pop(k, None)
                self.counters.removed += 1
        wanted = sorted(p for p in paths if self.rules.indexes(p))
        found, _ = files.look_up(self.root, wanted, self.attributes)
        for path, facts in found.items():  # a folder that could not be listed is not in ``found``: kept
            k = files.key(path)
            if facts is None:
                to_read.pop(k, None)
                if self.state.delete(k):
                    self.counters.removed += 1
            elif self.needs_read(facts):
                to_read[k] = facts
            else:
                to_read.pop(k, None)
        return to_read

    @staticmethod
    def _ordered(batch: dict[str, files.FileFacts]) -> list[files.FileFacts]:
        # PDFs first: they take a moment each, DWGs a few seconds each in AutoCAD.
        return sorted(batch.values(), key=lambda f: (files.kind_of(f.path) != "pdf", f.path.lower()))

    def _work(self, batch: dict[str, files.FileFacts]) -> set[str]:
        """Read a batch one file at a time. Between files the watcher's newest changes are gathered and go to the
        front, PDFs first, and are published as soon as they are read, so a saved file is never stuck behind a long
        scan or a large copy."""
        queue = deque(self._ordered(batch))
        total = len(queue)
        done: set[str] = set()
        urgent = 0
        last_log = last_publish = time.monotonic()
        while queue:
            if self.poll_changes is not None:
                fresh_batch = self.poll_changes()
                if fresh_batch is not None:
                    fresh = self._gather(set(fresh_batch[1]), set(fresh_batch[0]))
                    queue = deque(f for f in queue if files.key(f.path) not in fresh)
                    queue.extendleft(reversed(self._ordered(fresh)))
                    total += len(fresh)
                    urgent = len(fresh)
                    if not urgent:
                        self.publish()  # only deletions
                    continue
            facts = queue.popleft()
            self.take(facts)
            done.add(files.key(facts.path))
            now = time.monotonic()
            if urgent:
                urgent -= 1
                if not urgent:
                    self.publish()
                    last_publish = time.monotonic()
            if now - last_log >= self.progress_seconds:
                log.info("Read %d of %d (%d%%)", len(done), total, 100 * len(done) // max(total, 1))
                last_log = now
            if now - last_publish >= self.publish_every_seconds:
                self.publish()  # a long first scan shows its progress on the Duo as it goes
                last_publish = time.monotonic()
        self.state.commit()
        return done

    # --- Publishing ---

    def _manifest_in_dropbox(self) -> dict | None:
        """With no state file (purged, reinstalled, a new laptop), the manifest already in Dropbox/Vellum/Index, so the
        generation carries on rather than starting again at 1, and unchanged shards are not written again."""
        try:
            manifest = json.loads((self.index_folder / "index.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        if not isinstance(manifest, dict) or manifest.get("format") != 1:
            return None
        if not isinstance(manifest.get("generation"), int):
            return None
        log.info("No state file: carrying on from generation %d in %s", manifest["generation"], self.index_folder)
        return manifest

    def publish(self) -> dict | None:
        records = dict(self.state.records())
        entries = build_entries(records, self.projects)
        previous_raw = self.state.meta("manifest")
        previous = json.loads(previous_raw) if previous_raw else self._manifest_in_dropbox()
        manifest = self.writer.publish(entries, previous, self.state.thumbnail)
        if manifest is not None:
            self.state.set_meta("manifest", json.dumps(manifest))
            log.info("Published generation %d: %d drawings in %d shards",
                     manifest["generation"], manifest["drawings"], len(manifest["shards"]))
        current = manifest or previous or {"shards": []}
        orphans = self.writer.collect(current, entries, self.state.orphans(), time.time())
        self.state.set_orphans(orphans)
        kept = {r.facts.get("thumbnail") for r in records.values()} - {None}
        self.state.drop_thumbnails_except(kept)
        self.state.commit()
        return manifest
