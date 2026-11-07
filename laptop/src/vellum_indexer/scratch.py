"""Reading an online-only file from a copy on Zach's external drive (his decision on #66, 2026-11-07).

An online-only DWG or PDF is downloaded through the Dropbox API (dropbox_api.py) into the indexer's own subfolder of
the scratch folder, ``D:\\Vellum indexer\\scratch\\Vellum indexer copies`` unless settings.toml names another scratch
folder, read like any local file (AutoCAD's work copy of a DWG stays in that subfolder too), and the copy deleted
once what was read is saved. Nothing is deleted from Dropbox or from the laptop's Dropbox folder, and the placeholder
there is never opened.

The indexer deletes only inside the subfolder it made itself, marked by a file it wrote there, never by a name pattern
alone, and it refuses a scratch folder inside the Dropbox folder, or reached through a junction or symlink into it.

One file at a time, so the subfolder holds one copy at most. What a crash left there is deleted at the next start.
When the drive is unplugged, the laptop is not signed in to Dropbox, or the drive is short of space, online-only files
stay listed by name, unread, and are read when that changes; the log says why once, not once per file.
"""

from __future__ import annotations

import http.client
import logging
import os
import shutil
import uuid
from collections.abc import Callable
from pathlib import Path, PurePosixPath

from vellum_indexer.dropbox_api import DropboxClient, DropboxError, NotSignedIn

log = logging.getLogger("vellum_indexer")

PREFIX = "vellum-dl-"
OWN_FOLDER = "Vellum indexer copies"
MARKER = ".created-by-vellum-indexer"


class Unavailable(Exception):
    """No download now: the drive, the sign-in or the space is missing. Not the file's fault."""


def _real(path: Path) -> str:
    """The path with every junction and symlink on the way resolved, as far as it exists."""
    return os.path.normcase(os.path.realpath(path))


def is_inside(path: Path, folder: Path) -> bool:
    real_path, real_folder = _real(path), _real(folder)
    try:
        return os.path.commonpath([real_path, real_folder]) == real_folder
    except ValueError:  # different drives
        return False


class Downloader:
    def __init__(
        self,
        scratch: Path | None,
        client: DropboxClient | None,
        min_free_bytes: int = 5 * 1024**3,
        disk_usage: Callable[[Path], object] = shutil.disk_usage,
        drive_present: Callable[[Path], bool] = lambda p: Path(p.anchor or p).exists(),
        dropbox_root: Path | None = None,
    ):
        self.scratch = scratch
        self.client = client
        self.min_free_bytes = min_free_bytes
        self.disk_usage = disk_usage
        self.drive_present = drive_present
        self.dropbox_root = dropbox_root  # the indexer sets it
        self.reason: str | None = "not checked yet"
        self.downloads = 0

    @property
    def own(self) -> Path:
        return self.scratch / OWN_FOLDER

    @property
    def work(self) -> Path:
        """AutoCAD's work folder for a downloaded DWG, on the scratch drive like the DWG itself."""
        return self.own / "work"

    def _refusal(self) -> str | None:
        """Why the scratch folder must not be used at all, whatever else is true."""
        if self.scratch is None:
            return "no scratch folder is set (scratch_folder in settings.toml)"
        if self.dropbox_root is not None and is_inside(self.scratch, self.dropbox_root):
            return (f"the scratch folder {self.scratch} is inside the Dropbox folder (it resolves to "
                    f"{os.path.realpath(self.scratch)}); set scratch_folder to a folder outside Dropbox")
        if self.own.exists() and not (self.own / MARKER).is_file():
            return f"{self.own} was not made by the indexer; it is left alone"
        if self.own.exists() and _real(self.own) != os.path.normcase(os.path.join(_real(self.scratch), OWN_FOLDER)):
            return f"{self.own} is a link to somewhere else; it is left alone"
        return None

    def clean(self) -> int:
        """Delete what a crash left in the indexer's own subfolder: copies and AutoCAD work folders. Nothing outside
        it, and nothing at all unless the subfolder carries the indexer's marker."""
        refusal = self._refusal()
        if refusal is not None:
            if self.scratch is not None and self.dropbox_root is not None and is_inside(self.scratch,
                                                                                         self.dropbox_root):
                log.warning("Not cleaning the scratch folder: %s", refusal)
            return 0
        if not (self.own / MARKER).is_file():
            return 0
        gone = 0
        for entry in os.scandir(self.own):
            if entry.name == MARKER:
                continue
            try:
                if entry.is_dir(follow_symlinks=False):
                    shutil.rmtree(entry.path)
                else:
                    os.remove(entry.path)
                gone += 1
            except OSError:
                pass
        if gone:
            log.info("Deleted %d things a stop left in %s", gone, self.own)
        return gone

    def _why_not(self, size: int = 0) -> str | None:
        refusal = self._refusal()
        if refusal is not None:
            return refusal
        if self.client is None:
            return "no Dropbox app key is set (dropbox_app_key in settings.toml)"
        if not self.client.signed_in():
            return "the laptop is not signed in to Dropbox (vellum-indexer sign-in)"
        if not self.drive_present(self.scratch):
            return f"the scratch drive {self.scratch.anchor or self.scratch} is not there"
        try:
            if not self.own.exists():
                self.own.mkdir(parents=True)
                (self.own / MARKER).write_text("Made by Vellum's laptop indexer, which empties this folder.\n")
            free = self.disk_usage(self.own).free
        except OSError as error:
            return f"the scratch folder {self.scratch} can't be used ({error.strerror or error})"
        if free - size < self.min_free_bytes:
            kept = self.min_free_bytes // 1024**2
            return f"the scratch drive has {free // 1024**2} MB free, under the {kept} MB kept"
        return None

    def available(self, size: int = 0) -> bool:
        """Whether an online-only file can be downloaded now. Logs when that changes, never once per file."""
        reason = self._why_not(size)
        if reason != self.reason:
            if reason:
                log.warning("Online-only files stay unread for now: %s", reason)
            else:
                log.info("Online-only files are downloaded to %s, read, and the copy deleted", self.own)
            self.reason = reason
        return reason is None

    def fetch(self, db_path: str, size: int) -> Path:
        """Download one file to the indexer's own subfolder. The caller deletes the copy (``done``) once what was read
        is saved. Raises ``Unavailable`` or ``DropboxError``; either way nothing is left behind."""
        if not self.available(size):
            raise Unavailable(self.reason)
        dest = self.own / f"{PREFIX}{uuid.uuid4().hex[:12]}{PurePosixPath(db_path).suffix.lower()}"
        try:
            self.client.download(db_path, dest)
        except NotSignedIn as error:
            dest.unlink(missing_ok=True)
            self.available()
            raise Unavailable(str(error)) from None
        except (DropboxError, OSError, http.client.HTTPException) as error:
            dest.unlink(missing_ok=True)
            raise DropboxError(str(error) or type(error).__name__) from None
        self.downloads += 1
        return dest

    @staticmethod
    def done(copy: Path) -> None:
        copy.unlink(missing_ok=True)
