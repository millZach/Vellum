"""Plot requests from the Duo and the laptop's answers, plot request format 1 (docs/plot-requests.md, ADR-0018).

The Duo asks for a plot by writing one small file to ``Dropbox/Vellum/Plots/requests/<request>.json``; the laptop
answers beside it in ``<request>.answer.json``, which the Duo reads with one small download. The laptop also keeps a
check-in, ``Dropbox/Vellum/Plots/laptop.json``, rewritten every two minutes while the indexer runs, so the Duo can
tell the laptop is off.

Everything here is a file in ``Dropbox/Vellum/Plots``; nothing is written anywhere else, and a request is never
deleted by the laptop.
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from vellum_indexer.index import atomic_write

log = logging.getLogger("vellum_indexer")

FORMAT = 1
REQUESTS = "requests"
ANSWER_SUFFIX = ".answer.json"
CHECK_IN = "laptop.json"
CHECK_IN_SECONDS = 120
STALE_AFTER_SECONDS = 2 * CHECK_IN_SECONDS + 60
MAX_REQUEST_BYTES = 4096
# A file that doesn't parse yet may still be arriving: it is looked at again until it is this old, then refused.
SETTLE_SECONDS = 10.0
# An answer whose request the Duo has deleted (it read the answer) is deleted this long after.
ANSWER_GRACE_SECONDS = 3600

REQUEST_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{7,63}\.json$")
ENTRY_ID = re.compile(r"^[0-9a-f]{16}$")
ISO_TIME = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$")
FINAL = ("done", "failed")


def now_iso() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


class Refused(Exception):
    """A request that will never be plotted; the message is the answer's reason."""


class NotYet(Exception):
    """A request file that may still be arriving."""


@dataclass(frozen=True)
class PlotRequest:
    name: str  # the request's file name less .json: its own id
    id: str  # the drawing index entry's id
    path: str  # the DWG's Dropbox path, as the index lists it
    layout: str | None
    asked: str


def request_name(file_name: str) -> str | None:
    """The request id for a file in the requests folder, or None for a file that is not a request (an answer, a
    temp file, anything else)."""
    if file_name.endswith(ANSWER_SUFFIX) or not REQUEST_NAME.match(file_name):
        return None
    return file_name[: -len(".json")]


def decode(name: str, data: bytes, age_seconds: float = SETTLE_SECONDS) -> PlotRequest:
    """A request file's bytes, checked. Raises ``Refused`` with a plain reason, or ``NotYet`` when it does not parse
    but is young enough to still be arriving."""
    if len(data) > MAX_REQUEST_BYTES:
        raise Refused("the request is too big to be a plot request")
    try:
        body = json.loads(data.decode("utf-8-sig"))
    except (UnicodeDecodeError, ValueError):
        if age_seconds < SETTLE_SECONDS:
            raise NotYet(name) from None
        raise Refused("the request couldn't be read") from None
    if not isinstance(body, dict):
        raise Refused("the request couldn't be read")
    if body.get("format") != FORMAT:
        raise Refused(f"the request is in format {body.get('format')!r}; this laptop reads plot request format 1")
    entry_id, path, layout, asked = body.get("id"), body.get("path"), body.get("layout"), body.get("asked")
    if not isinstance(entry_id, str) or not ENTRY_ID.match(entry_id):
        raise Refused("the request names no drawing index entry")
    if not isinstance(path, str) or not path.startswith("/") or not path.lower().endswith(".dwg") or len(path) > 1024:
        raise Refused("the request names no DWG")
    if any(part in ("..", ".") for part in path.split("/")) or "\\" in path or "\x00" in path:
        raise Refused("the request's path isn't a Dropbox path")
    if layout is not None and (not isinstance(layout, str) or not layout or len(layout) > 255):
        raise Refused("the request's layout isn't a layout name")
    if not isinstance(asked, str) or not ISO_TIME.match(asked):
        raise Refused("the request doesn't say when it was asked")
    return PlotRequest(name, entry_id, path, layout, asked)


@dataclass
class Answer:
    request: str
    state: str  # "plotting", "done" or "failed"
    id: str | None = None
    pdf: str | None = None
    content_hash: str | None = None
    page_setup: str | None = None  # "saved" or "fallback"
    reason: str | None = None
    updated: str = ""

    def to_json(self) -> dict:
        return {
            "format": FORMAT,
            "request": self.request,
            "id": self.id,
            "state": self.state,
            "updated": self.updated or now_iso(),
            "pdf": self.pdf,
            "contentHash": self.content_hash,
            "pageSetup": self.page_setup,
            "reason": self.reason,
        }


class PlotFolder:
    """``Dropbox/Vellum/Plots``: the requests and answers in it, and the laptop's check-in."""

    def __init__(self, folder: Path, clock=time.time):
        self.folder = folder
        self.requests = folder / REQUESTS
        self.clock = clock

    def pending(self) -> list[tuple[str, Path]]:
        """Requests with no final answer, oldest first: (request id, file). A request answered ``plotting`` only is
        one a stop interrupted, and is plotted again."""
        try:
            entries = list(os.scandir(self.requests))
        except OSError:
            return []
        names = {e.name for e in entries}
        out = []
        for entry in entries:
            name = request_name(entry.name)
            if name is None or not entry.is_file(follow_symlinks=False):
                continue
            if f"{name}{ANSWER_SUFFIX}" in names and self.answer_state(name) in FINAL:
                continue
            try:
                mtime = entry.stat(follow_symlinks=False).st_mtime
            except OSError:
                continue
            out.append((mtime, name, Path(entry.path)))
        return [(name, path) for _, name, path in sorted(out)]

    def read(self, name: str, path: Path) -> PlotRequest:
        try:
            st = path.stat()
            if st.st_size > MAX_REQUEST_BYTES:
                raise Refused("the request is too big to be a plot request")
            data = path.read_bytes()
        except OSError:
            raise NotYet(name) from None
        return decode(name, data, self.clock() - st.st_mtime)

    def answer_state(self, name: str) -> str | None:
        try:
            body = json.loads((self.requests / f"{name}{ANSWER_SUFFIX}").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return body.get("state") if isinstance(body, dict) else None

    def answer(self, answer: Answer) -> None:
        data = (json.dumps(answer.to_json(), ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode("utf-8")
        atomic_write(self.requests / f"{answer.request}{ANSWER_SUFFIX}", data)

    def clean(self) -> int:
        """Delete answers whose request the Duo deleted, an hour after. A request is never deleted here: the Duo
        deletes its own once it has read a final answer."""
        try:
            entries = list(os.scandir(self.requests))
        except OSError:
            return 0
        names = {e.name for e in entries}
        gone = 0
        for entry in entries:
            if not entry.name.endswith(ANSWER_SUFFIX) or entry.name.startswith("~$"):
                continue
            request = entry.name[: -len(ANSWER_SUFFIX)] + ".json"
            if request in names:
                continue
            try:
                if self.clock() - entry.stat(follow_symlinks=False).st_mtime >= ANSWER_GRACE_SECONDS:
                    os.remove(entry.path)
                    gone += 1
            except OSError:
                pass
        return gone

    def make_requests_folder(self) -> None:
        """Make ``requests/`` if it is not there, so the Duo's first request lands in a folder already watched."""
        try:
            self.requests.mkdir(parents=True, exist_ok=True)
        except OSError as error:
            log.warning("Could not make %s: %s", self.requests, error)

    def check_in(self, version: str) -> None:
        body = {"format": FORMAT, "seen": now_iso(), "indexer": version, "every": CHECK_IN_SECONDS,
                "staleAfter": STALE_AFTER_SECONDS}
        atomic_write(self.folder / CHECK_IN, (json.dumps(body, sort_keys=True) + "\n").encode("utf-8"))


class CheckIn:
    """Rewrites the check-in every two minutes on its own thread, so a long plot or a long listing never makes the
    laptop look off. It writes one small file and touches nothing else."""

    def __init__(self, plots: PlotFolder, version: str, every: float = CHECK_IN_SECONDS):
        self.plots = plots
        self.version = version
        self.every = every
        self.stop = threading.Event()
        self.thread: threading.Thread | None = None
        self.writes = 0

    def beat(self) -> None:
        try:
            self.plots.check_in(self.version)
            self.writes += 1
        except OSError as error:
            log.warning("Could not write the check-in: %s", error)

    def start(self) -> None:
        self.beat()
        self.thread = threading.Thread(target=self._run, name="check-in", daemon=True)
        self.thread.start()

    def _run(self) -> None:
        while not self.stop.wait(self.every):
            self.beat()

    def close(self) -> None:
        self.stop.set()
        if self.thread is not None:
            self.thread.join(5)
