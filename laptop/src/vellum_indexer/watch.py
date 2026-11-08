"""Watching the Dropbox folder for changes, debounced, so copying a folder of drawings is one update, not hundreds.

Changes are gathered until the folder has been quiet for ``quiet`` seconds (2 by default), or for at most
``max_wait`` seconds (30) while changes keep coming, then handed to the indexer at once. Changes inside
Dropbox/Vellum (the index itself, canvases) are not drawings and are left out by the skip rules, except a plot request
arriving in Dropbox/Vellum/Plots/requests: that is not debounced, and is answered ahead of anything waiting.
"""

from __future__ import annotations

import logging
import threading
import time
from collections.abc import Callable
from pathlib import Path

from vellum_indexer import files
from vellum_indexer.plot_requests import request_name

log = logging.getLogger("vellum_indexer")


class Debouncer:
    def __init__(self, quiet: float = 2.0, max_wait: float = 30.0, clock: Callable[[], float] = time.monotonic):
        self.quiet = quiet
        self.max_wait = max_wait
        self.clock = clock
        self.lock = threading.Lock()
        self.paths: set[str] = set()
        self.folders: set[str] = set()
        self.first: float | None = None
        self.last: float | None = None

    def add(self, path: str, folder: bool = False) -> None:
        with self.lock:
            (self.folders if folder else self.paths).add(path)
            now = self.clock()
            self.first = self.first if self.first is not None else now
            self.last = now

    def due(self) -> bool:
        with self.lock:
            if self.first is None:
                return False
            now = self.clock()
            return now - self.last >= self.quiet or now - self.first >= self.max_wait

    def take(self) -> tuple[set[str], set[str]]:
        with self.lock:
            out = (self.paths, self.folders)
            self.paths, self.folders = set(), set()
            self.first = self.last = None
            return out


PLOT_REQUESTS = "/vellum/plots/requests/"


class DropboxEvents:
    """Turns watchdog's events into Dropbox paths for the debouncer, keeping only what the indexer cares about. A plot
    request arriving calls ``on_plot_request`` at once."""

    def __init__(self, root: Path, rules: files.SkipRules, debouncer: Debouncer,
                 on_plot_request: Callable[[], None] | None = None):
        self.root = root
        self.rules = rules
        self.debouncer = debouncer
        self.on_plot_request = on_plot_request

    def _db(self, raw: str | bytes) -> str | None:
        path = Path(raw.decode() if isinstance(raw, bytes) else raw)
        try:
            path.relative_to(self.root)
        except ValueError:
            return None
        return files.dropbox_path(self.root, path)

    def handle(self, event_type: str, src: str, dest: str | None, is_directory: bool) -> None:
        for raw in [src] + ([dest] if dest else []):
            db = self._db(raw)
            if db is None or db == "/":
                continue
            lower = db.lower()
            if lower.startswith("/vellum/plots"):
                log.debug("Plots folder event: %s %s", event_type, db)
            if lower.startswith(PLOT_REQUESTS) or lower == PLOT_REQUESTS.rstrip("/"):
                rest = lower[len(PLOT_REQUESTS):]
                wake = (event_type != "deleted" and "/" not in rest
                        and (is_directory or not rest or request_name(db.rsplit("/", 1)[1]) is not None))
                if wake and self.on_plot_request:
                    log.debug("Plot request event: %s %s", event_type, db)
                    self.on_plot_request()
                continue
            if is_directory:
                if event_type == "modified" or self.rules.skips_folder(db):
                    continue  # a folder's modified time changes with every file in it
                self.debouncer.add(db, folder=True)
            elif self.rules.indexes(db):
                self.debouncer.add(db)
            elif event_type in ("deleted", "moved") and files.kind_of(db) is None and not self.rules.skips_folder(db):
                # On Windows a deletion cannot say whether it was a folder; a path that is not a drawing may be one.
                self.debouncer.add(db, folder=True)

    def dispatch(self, event) -> None:  # watchdog's FileSystemEventHandler interface
        if event.event_type in ("opened", "closed", "closed_no_write"):
            return
        self.handle(event.event_type, event.src_path, getattr(event, "dest_path", None) or None, event.is_directory)


def watch(
    indexer,
    quiet: float,
    max_wait: float,
    rescan_hours: float,
    stop: threading.Event | None = None,
    retry_minutes: float = 10.0,
    check_in_seconds: float | None = None,
) -> None:
    """Scan, then watch until ``stop`` is set, updating the index from each debounced batch of changes."""
    from watchdog.observers import Observer

    from vellum_indexer import __version__
    from vellum_indexer.plot_requests import CHECK_IN_SECONDS, Acknowledger, CheckIn

    stop = stop or threading.Event()
    debouncer = Debouncer(quiet, max_wait)
    # A request is answered "queued" by the acknowledger's thread the moment it is seen, even while the indexer is
    # part way through a long read; the indexer plots it as soon as that read ends.
    acknowledger = Acknowledger(indexer.plot_folder, on_new=indexer.plot_wanted.set)
    indexer.acknowledger = acknowledger

    def request_seen() -> None:
        acknowledger.wake()
        indexer.plot_wanted.set()

    handler = DropboxEvents(indexer.root, indexer.rules, debouncer, on_plot_request=request_seen)
    indexer.plot_folder.make_requests_folder()
    observer = Observer()
    observer.schedule(handler, str(indexer.root), recursive=True)
    observer.start()  # before the scan, so nothing changed during it is missed
    log.info("Watching %s", indexer.root)
    indexer.poll_changes = lambda: debouncer.take() if debouncer.due() else None
    check_in = CheckIn(indexer.plot_folder, __version__, check_in_seconds or CHECK_IN_SECONDS)
    check_in.start()
    indexer.check_in = check_in
    acknowledger.start()
    try:
        indexer.answer_plot_requests()  # requests that came while the laptop was off, before the scan's listing
        indexer.scan()
        next_rescan = time.monotonic() + rescan_hours * 3600
        next_retry = time.monotonic() + retry_minutes * 60
        while not stop.is_set():
            indexer.plot_wanted.wait(0.5)  # wakes at once for a plot request, else every half second
            if stop.is_set():
                break
            if indexer.plots_due():
                indexer.answer_plot_requests()
            if debouncer.due():
                paths, folders = debouncer.take()
                started = time.monotonic()
                indexer.update(paths, folders)
                log.info("Updated %d files and %d folders in %.2f s", len(paths), len(folders),
                         time.monotonic() - started)
            elif time.monotonic() >= next_rescan:
                indexer.scan()  # in case a change notification was lost
                next_rescan = time.monotonic() + rescan_hours * 3600
            elif time.monotonic() >= next_retry:
                indexer.retry_unread()  # the drive plugged back in, signed in, or Dropbox no longer busy
                next_retry = time.monotonic() + retry_minutes * 60
            if not observer.is_alive():
                log.error("The Dropbox watcher stopped; restarting it")
                observer = Observer()
                observer.schedule(handler, str(indexer.root), recursive=True)
                observer.start()
                indexer.scan()
    finally:
        acknowledger.close()
        check_in.close()
        observer.stop()
        observer.join(timeout=5)
