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
import os
import threading
import time
from collections import deque
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path

from vellum_indexer import dwg as dwg_module
from vellum_indexer import fields, files
from vellum_indexer import pdf as pdf_module
from vellum_indexer import plot as plot_module
from vellum_indexer.dropbox_api import DropboxError
from vellum_indexer.index import IndexWriter, atomic_write, build_entries, content_name, entry_id, sheets_of
from vellum_indexer.plot_requests import Answer, NotYet, PlotFolder, PlotRequest, Refused, missing_warning
from vellum_indexer.projects import ProjectFinder
from vellum_indexer.scratch import Downloader, Unavailable, is_inside
from vellum_indexer.state import Plot, Record, State

log = logging.getLogger("vellum_indexer")

PDF_READER_ID = "pdfium-1"
UNREAD = "unread"
INDEX_FOLDER = ("Vellum", "Index")
# Plot requests are looked for when the watcher sees one arrive, and this often anyway in case a notice was lost.
PLOT_LOOK_SECONDS = 60.0
PLOT_ARRIVING_SECONDS = 2.0


@dataclass
class Counters:
    stat_files: int = 0
    pdfs_read: int = 0
    dwgs_read: int = 0
    online_only_listed: int = 0
    downloaded: int = 0
    thumbnails_made: int = 0
    removed: int = 0
    plots_made: int = 0
    plot_answers: int = 0

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
        plotter: plot_module.Plotter | None = None,
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
        self.plotter = plotter or plot_module.NoPlotter()
        self.plots_root = root.joinpath(*plot_module.PLOTS_FOLDER)
        self.plot_folder = PlotFolder(self.plots_root)
        self.plot_wanted = threading.Event()  # set by the watcher when a request arrives
        self.plot_wanted.set()  # look once at the start: requests may have come while the laptop was off
        self.next_plot_look = 0.0
        self._plotting = False
        self._plot_ran = False  # whether the last look ran AutoCAD (one plot per turn)
        self.check_in = None  # the watcher's check-in thread, while it runs
        self.acknowledger = None  # and its plot request acknowledger
        if downloader is not None:
            downloader.dropbox_root = root  # a scratch folder inside Dropbox is refused
            downloader.clean()  # copies and work folders a crash left behind
        if hasattr(self.dwg_reader, "clean"):
            self.dwg_reader.clean()

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
        if not facts.online_only:
            # It may have been made online-only since it was listed: look again, from its folder's listing (no
            # stat, no open), right before opening it, so a placeholder is never opened.
            found, _ = files.look_up(self.root, [facts.path], self.attributes)
            now = found.get(facts.path, facts)
            if now is None:
                return  # gone since: its deletion comes as its own change
            facts = now
        old = self.state.get(key)
        if (old is not None and old.path == facts.path and old.reader == self._reader_id(kind)
                and (old.size, old.mtime_ns) == (facts.size, facts.mtime_ns)):
            # Only made online-only (or made local again) with nothing changed: what was read still holds, and
            # nothing is downloaded or read again.
            self.state.put(key, Record(facts.path, kind, facts.size, facts.mtime_ns, facts.online_only, old.reader,
                                       old.facts))
            return
        copy = None
        work = None
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
            work = self.downloader.work  # AutoCAD's copy stays on the scratch drive too
        else:
            local = files.local_path(self.root, facts.path)
        try:
            try:
                read = self._read(kind, local, work)
            except OSError as error:
                # Locked or vanished part way (AutoCAD saving it, Dropbox syncing it): keep what was known and try
                # again with the next change or scan.
                log.info("Could not open %s yet: %s", local, error)
                return
            reader = self._reader_id(kind)
            if kind == "dwg" and "error" in read:
                reader += "-failed"  # read again at the next full scan, in case AutoCAD failed for a moment
            self.state.put(key, Record(facts.path, kind, facts.size, facts.mtime_ns, facts.online_only, reader, read))
            if copy is not None:
                self.state.commit()  # saved before the copy goes, so a crash never downloads it again
        finally:
            if copy is not None:
                Downloader.done(copy)

    def _unread(self, key: str, facts: files.FileFacts, kind: str) -> None:
        self.counters.online_only_listed += 1
        old = self.state.get(key)
        if old is not None and old.reader != UNREAD and (old.size, old.mtime_ns) == (facts.size, facts.mtime_ns):
            # Freed up to online-only with nothing changed: what was read still holds.
            self.state.put(key, Record(facts.path, kind, facts.size, facts.mtime_ns, True, old.reader, old.facts))
            return
        self.state.put(key, Record(facts.path, kind, facts.size, facts.mtime_ns, True, UNREAD, {}))

    def _read(self, kind: str, local: Path, work: Path | None = None) -> dict:
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
            inserts = self.dwg_reader.read(local, work=work) if work else self.dwg_reader.read(local)
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
        self._drop_missing_plots()
        to_read, _ = self._gather({"/"}, set())
        log.info("Listed %d drawings and PDFs in %.1f s; %d to read", self.counters.stat_files,
                 time.monotonic() - started, len(to_read))
        self._work(to_read)
        self.publish()
        self.answer_plot_requests()
        log.info("Scan done in %.1f s", time.monotonic() - started)

    def update(self, paths: Iterable[str], folders: Iterable[str] = ()) -> set[str]:
        """What the watcher saw: Dropbox paths of files changed, made or deleted, and of folders made, moved in or
        deleted. Reads only those, then publishes. Returns the keys of the files it read."""
        read = self._work(self._gather(set(folders), set(paths))[0])
        self.publish()
        return read

    def retry_unread(self) -> set[str]:
        """Online-only files listed unread, read now if they can be downloaded (the drive is back, signed in)."""
        if not self._can_download():
            return set()
        waiting = {r.path for _, r in self.state.records() if r.reader == UNREAD}
        return self.update(waiting) if waiting else set()

    def _gather(self, folders: set[str], paths: set[str]) -> tuple[dict[str, files.FileFacts], set[str]]:
        """The one collector for the scan and the watcher: walk the folders, look up the paths, drop from the state
        file what is gone, and return what to read, one entry per path (a path met twice in a batch, as a folder copy
        reports it, is read once). Nothing under a folder that could not be listed is dropped."""
        to_read: dict[str, files.FileFacts] = {}
        gone: set[str] = set()
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
                    if self.counters.stat_files % 256 == 0:
                        self.answer_plot_requests()  # even while a first scan lists all of Dropbox
                    k = files.key(facts.path)
                    present.add(k)
                    if self.needs_read(facts):
                        to_read[k] = facts
            for k in [k for k in self.state.all_keys() if k.startswith(prefix) and k not in present and not kept(k)]:
                self.state.delete(k)
                to_read.pop(k, None)
                gone.add(k)
                self.counters.removed += 1
        wanted = sorted(p for p in paths if self.rules.indexes(p))
        found, _ = files.look_up(self.root, wanted, self.attributes)
        for path, facts in found.items():  # a folder that could not be listed is not in ``found``: kept
            k = files.key(path)
            if facts is None:
                to_read.pop(k, None)
                gone.add(k)
                if self.state.delete(k):
                    self.counters.removed += 1
            elif self.needs_read(facts):
                to_read[k] = facts
            else:
                to_read.pop(k, None)
        return to_read, gone

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
        plot_turn = True
        while queue:
            # A plot request goes ahead of every file waiting to be read, one plot a turn: after a plot the watcher's
            # changes and the next file come first, so a backlog of plots never holds up the index.
            if plot_turn:
                self.answer_plot_requests()
                plot_turn = not self._plot_ran
            if self.poll_changes is not None:
                fresh_batch = self.poll_changes()
                if fresh_batch is not None:
                    fresh, gone = self._gather(set(fresh_batch[1]), set(fresh_batch[0]))
                    # a newer change to a queued path replaces it; a deletion drops it, so it never comes back
                    queue = deque(f for f in queue if files.key(f.path) not in fresh and files.key(f.path) not in gone)
                    queue.extendleft(reversed(self._ordered(fresh)))
                    total += len(fresh)
                    urgent = len(fresh)
                    if not urgent:
                        self.publish()  # only deletions
                    continue
            facts = queue.popleft()
            self.take(facts)
            plot_turn = True
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
        entries = build_entries(records, self.projects, self.state.plots())
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

    # --- Plotting on request (#67, docs/plot-requests.md) ---

    def plots_due(self) -> bool:
        return self.plot_wanted.is_set() or time.monotonic() >= self.next_plot_look

    def answer_plot_requests(self) -> int:
        """Answer the plot requests waiting in Dropbox/Vellum/Plots/requests, oldest first, running AutoCAD at most
        once: requests refused or answered from a plot already made cost nothing, but after one plot the rest wait
        for the next turn, so the watcher's changes and the scan are taken between plots. Cheap when none is due: a
        flag and a clock. Returns how many were answered."""
        self._plot_ran = False
        if self._plotting or not self.plots_due():
            return 0
        self._plotting = True
        try:
            self.plot_wanted.clear()
            answered = 0
            arriving = False
            pending = self.plot_folder.pending()
            for i, (name, path) in enumerate(pending):
                try:
                    result = self._answer_one(name, path)
                except Exception as error:  # noqa: BLE001 - no request, however made, stops the indexer
                    log.exception("Could not handle plot request %s", name)
                    self._answer(Answer(name, "failed", reason=f"the laptop couldn't handle this request "
                                                               f"({type(error).__name__})"))
                    result = True
                answered += result is True
                arriving |= result is None
                if self._plot_ran and i + 1 < len(pending):
                    self.plot_wanted.set()  # the rest at the next turn
                    break
            self.plot_folder.clean()
            # a request still arriving is looked at again in a couple of seconds
            self.next_plot_look = time.monotonic() + (PLOT_ARRIVING_SECONDS if arriving else PLOT_LOOK_SECONDS)
            return answered
        finally:
            self._plotting = False

    def _answer(self, answer: Answer) -> None:
        try:
            self.plot_folder.answer(answer)
            self.counters.plot_answers += 1
        except OSError as error:
            log.warning("Could not answer plot request %s: %s", answer.request, error)

    def _answer_one(self, name: str, path: Path) -> bool | None:
        """True once answered; None for a request still arriving."""
        try:
            request = self.plot_folder.read(name, path)
        except NotYet:
            return None
        except Refused as refused:
            log.info("Refused plot request %s: %s", name, refused)
            self._answer(Answer(name, "failed", reason=str(refused)))
            return True
        try:
            dwg_key, record, layout = self._entry_of(request)
        except Refused as refused:
            log.info("Refused plot request %s: %s", name, refused)
            self._answer(Answer(name, "failed", id=request.id, reason=str(refused)))
            return True
        self._answer(Answer(name, "plotting", id=request.id))
        try:
            plot, page_setup = self._plot(dwg_key, record, layout)
        except Refused as failed:
            log.warning("Could not plot %s (%s): %s", record.path, layout or "its saved layout", failed)
            self._answer(Answer(name, "failed", id=request.id, reason=str(failed)))
            return True
        self.publish()  # the index lists the PDF before the answer says done, so the Duo finds it there
        missing = plot.facts.get("missingReferences") or 0
        self._answer(Answer(name, "done", id=request.id, pdf=plot.path, content_hash=plot.facts.get("contentHash"),
                            page_setup=page_setup,
                            reason=None if page_setup != "fallback" else
                            plot_module.fallback_reason(plot.facts.get("plottedLayout") or layout),
                            missing_references=missing, warning=missing_warning(missing)))
        return True

    def _entry_of(self, request: PlotRequest) -> tuple[str, Record, str | None]:
        """The DWG and layout a request names, from what the index holds: the request must name an entry's id, its
        DWG's path and its layout exactly, and from here on only the index's own path and layout are used."""
        key = files.key(request.path)
        record = self.state.get(key)
        if record is None or record.kind != "dwg" or self.rules.skips_file(record.path):
            raise Refused("the drawing isn't in the drawing index")
        for sheet in sheets_of(record):
            layout = sheet.layout or None
            if (entry_id(record.path, layout) == request.id
                    and (layout or "").lower() == (request.layout or "").lower()):
                return key, record, layout
        raise Refused("the request doesn't match the drawing index (the drawing's layouts may have changed)")

    def _plot(self, dwg_key: str, record: Record, layout: str | None) -> tuple[Plot, str]:
        sheet = f"{dwg_key}#{(layout or '').lower()}"
        found, _ = files.look_up(self.root, [record.path], self.attributes)  # from the listing: no stat, no open
        facts = found.get(record.path)
        if facts is None:
            raise Refused("the DWG isn't in Dropbox any more")
        for plot in self.state.plots():  # asked twice (two taps, two Duos): the same DWG gives the same plot
            if (plot.sheet == sheet and (plot.dwg_size, plot.dwg_mtime_ns) == (facts.size, facts.mtime_ns)
                    and files.local_path(self.root, plot.path).is_file()):
                return plot, plot.facts.get("pageSetup") or "saved"
        copy = None
        work = None
        if facts.online_only:
            if self.downloader is None:
                raise Refused("the DWG is online-only, and the laptop isn't set up to download it")
            try:
                copy = self.downloader.fetch(facts.path, facts.size)
            except Unavailable as error:
                raise Refused(f"the DWG is online-only, and the laptop can't download it now: {error}") from None
            except DropboxError:
                raise Refused("the DWG is online-only, and its download from Dropbox failed") from None
            self.counters.downloaded += 1
            local, work = copy, self.downloader.work
        else:
            local = files.local_path(self.root, facts.path)
            if not is_inside(local, self.root):
                raise Refused("the DWG isn't in Dropbox")
        origin = files.local_path(self.root, facts.path).parent  # where its relative references are, in Dropbox
        try:
            try:
                version = plot_module.file_version(local)
            except OSError:
                raise Refused("the DWG couldn't be read") from None
            self._plot_ran = True
            try:
                result = self.plotter.plot(local, layout, work, origin)
            except plot_module.PlotError as error:
                raise Refused(str(error)) from None
        finally:
            if copy is not None:
                Downloader.done(copy)
        project = self.projects.project_of(record.path)
        db_pdf = plot_module.plot_name(project.name, record.path, layout, facts.mtime_ns, version)
        dest = files.local_path(self.root, db_pdf)
        if not is_inside(dest, self.plots_root):
            raise Refused("the plot's name would put it outside Dropbox/Vellum/Plots")
        try:
            atomic_write(dest, result.pdf)
            st = os.stat(dest)
            read = self._read("pdf", dest)
        except OSError as error:
            raise Refused(f"the PDF couldn't be saved in Dropbox/Vellum/Plots ({error.strerror or error})") from None
        read["pageSetup"] = result.page_setup
        read["plottedLayout"] = result.layout or layout  # a request with no layout: the layout AutoCAD plotted
        read["references"] = result.references
        read["missingReferences"] = result.missing
        plot = Plot(sheet, facts.size, facts.mtime_ns, db_pdf, st.st_size, st.st_mtime_ns, read)
        self.state.put_plot(plot)
        self.counters.plots_made += 1
        log.info("Plotted %s (%s) to %s with %s page setup", record.path, layout or "its saved layout", db_pdf,
                 "its own" if result.page_setup == "saved" else
                 "DWG To PDF, the Model tab's extents at 1:1, as a fallback," if plot_module.is_model(result.layout)
                 else "DWG To PDF at its paper size, as a fallback,")
        return plot, result.page_setup

    def _drop_missing_plots(self) -> None:
        """Forget plots whose PDF is no longer in Dropbox/Vellum/Plots (deleted there by hand), from the listing."""
        plots = self.state.plots()
        if not plots:
            return
        found, _ = files.look_up(self.root, [p.path for p in plots], self.attributes)
        for plot in plots:
            if plot.path in found and found[plot.path] is None:
                self.state.delete_plot(plot.path)
