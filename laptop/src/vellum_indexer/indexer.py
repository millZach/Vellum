"""The laptop indexer's work: scan the Dropbox folder, read what changed, and publish the drawing index.

A file is read only when its size, modified time or online-only state differs from the state file's, or its reader
changed (AutoCAD installed since). An online-only file is listed by its path and name and never opened: opening one
makes Dropbox download it. It is read once it is local.
"""

from __future__ import annotations

import json
import logging
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path

from vellum_indexer import dwg as dwg_module
from vellum_indexer import fields, files
from vellum_indexer import pdf as pdf_module
from vellum_indexer.index import IndexWriter, build_entries, content_name
from vellum_indexer.projects import ProjectFinder
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
        return not facts.online_only and record.reader != self._reader_id(record.kind)

    def take(self, facts: files.FileFacts) -> None:
        """Read one file (or list it unread when it is online-only) and keep what was read."""
        kind = files.kind_of(facts.path)
        if facts.online_only:
            self.counters.online_only_listed += 1
            record = Record(facts.path, kind, facts.size, facts.mtime_ns, True, UNREAD, {})
        else:
            local = files.local_path(self.root, facts.path)
            try:
                read = self._read(kind, local)
            except OSError as error:
                # Locked or vanished part way (AutoCAD saving it, Dropbox syncing it): keep what was known and try
                # again with the next change or scan.
                log.info("Could not open %s yet: %s", local, error)
                return
            reader = self._reader_id(kind)
            if kind == "dwg" and "error" in read:
                reader += "-failed"  # read again at the next full scan, in case AutoCAD failed for a moment
            record = Record(facts.path, kind, facts.size, facts.mtime_ns, False, reader, read)
        self.state.put(files.key(facts.path), record)

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
            out["attributes"] = fields.from_attributes(inserts, self.tags).as_dict()
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
        self._unlisted: list[str] = []
        seen: set[str] = set()
        changed: list[files.FileFacts] = []
        for facts in files.walk(self.root, self.rules, attributes=self.attributes, on_error=self._walk_error):
            self.counters.stat_files += 1
            seen.add(files.key(facts.path))
            if self.needs_read(facts):
                changed.append(facts)
        listed = time.monotonic() - started
        log.info("Listed %d drawings and PDFs in %.1f s; %d to read", len(seen), listed, len(changed))
        # A folder that could not be listed this time keeps what it had, rather than everything in it being read again.
        unlisted = tuple(files.key(f).rstrip("/") + "/" for f in self._unlisted)
        for key in self.state.all_keys() - seen:
            if unlisted and key.startswith(unlisted):
                continue
            self.state.delete(key)
            self.counters.removed += 1
        # PDFs first: they take a moment each, DWGs a few seconds each in AutoCAD, so a long first scan has every
        # drawing with a PDF in the index early, and DWG fields refine it after.
        changed.sort(key=lambda f: files.kind_of(f.path) != "pdf")
        self._read_all(changed, poll=True)
        self.publish()
        log.info("Scan done in %.1f s", time.monotonic() - started)

    def _read_all(self, changed: list[files.FileFacts], poll: bool = False) -> set[str]:
        """Read each file. During a scan (``poll``), changes the watcher has gathered are taken between files, so a
        saved PDF reaches the index within seconds even while a first scan runs for hours."""
        last_log = last_publish = time.monotonic()
        taken_by_updates: set[str] = set()
        for i, facts in enumerate(changed, 1):
            if poll and self.poll_changes is not None:
                batch = self.poll_changes()
                if batch is not None:
                    taken_by_updates |= self.update(*batch)
            if files.key(facts.path) in taken_by_updates:
                continue
            self.take(facts)
            now = time.monotonic()
            if now - last_log >= self.progress_seconds:
                log.info("Read %d of %d (%d%%)", i, len(changed), 100 * i // len(changed))
                last_log = now
            if now - last_publish >= self.publish_every_seconds:
                self.publish()  # a long first scan shows its progress on the Duo as it goes
                last_publish = time.monotonic()
        self.state.commit()
        return {files.key(f.path) for f in changed}

    def _walk_error(self, path: Path, error: OSError) -> None:
        log.warning("Could not list %s: %s", path, error)
        self._unlisted.append(files.dropbox_path(self.root, path))

    def update(self, paths: Iterable[str], folders: Iterable[str] = ()) -> set[str]:
        """What the watcher saw: Dropbox paths of files changed, made or deleted, and of folders made, moved in or
        deleted. Reads only those, then publishes. Returns the keys of the files it read."""
        changed: list[files.FileFacts] = []
        for folder in sorted(set(folders)):
            if self.rules.skips_folder(folder):
                continue
            if files.local_path(self.root, folder).is_dir():
                present = set()
                for facts in files.walk(self.root, self.rules, start=folder, attributes=self.attributes):
                    present.add(files.key(facts.path))
                    if self.needs_read(facts):
                        changed.append(facts)
                # anything the state file has under it that is no longer there
                prefix = files.key(folder).rstrip("/") + "/"
                for key in [k for k in self.state.all_keys() if k.startswith(prefix) and k not in present]:
                    self.state.delete(key)
                    self.counters.removed += 1
            else:
                self.counters.removed += self.state.delete_under(files.key(folder))
        wanted = sorted(p for p in set(paths) if self.rules.indexes(p))
        for path, facts in files.stat_files(self.root, wanted, self.attributes).items():
            if facts is None:
                if self.state.delete(files.key(path)):
                    self.counters.removed += 1
            elif self.needs_read(facts):
                changed.append(facts)
        taken = self._read_all(changed)
        self.publish()
        return taken

    # --- Publishing ---

    def publish(self) -> dict | None:
        records = dict(self.state.records())
        entries = build_entries(records, self.projects)
        previous_raw = self.state.meta("manifest")
        previous = json.loads(previous_raw) if previous_raw else None
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
