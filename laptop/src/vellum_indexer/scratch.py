"""Reading an online-only file from a copy on Zach's external drive (his decision on #66, 2026-11-07).

An online-only DWG or PDF is downloaded through the Dropbox API (dropbox_api.py) into the scratch folder,
``D:\\Vellum indexer\\scratch`` unless settings.toml names another, read like any local file, and the copy deleted at
once. Nothing is deleted from Dropbox or from the laptop's Dropbox folder, and the placeholder there is never opened.

One file at a time, so the scratch folder holds one copy at most. A copy left by a crash is deleted at the next start.
When the drive is unplugged, the laptop is not signed in to Dropbox, or the drive is short of space, online-only files
stay listed by name, unread, and are read when that changes; the log says why once, not once per file.
"""

from __future__ import annotations

import logging
import os
import shutil
import uuid
from collections.abc import Callable
from pathlib import Path, PurePosixPath

from vellum_indexer.dropbox_api import DropboxClient, DropboxError, NotSignedIn

log = logging.getLogger("vellum_indexer")

PREFIX = "vellum-dl-"


class Unavailable(Exception):
    """No download now: the drive, the sign-in or the space is missing. Not the file's fault."""


class Downloader:
    def __init__(
        self,
        scratch: Path | None,
        client: DropboxClient | None,
        min_free_bytes: int = 5 * 1024**3,
        disk_usage: Callable[[Path], object] = shutil.disk_usage,
        drive_present: Callable[[Path], bool] = lambda p: Path(p.anchor or p).exists(),
    ):
        self.scratch = scratch
        self.client = client
        self.min_free_bytes = min_free_bytes
        self.disk_usage = disk_usage
        self.drive_present = drive_present
        self.reason: str | None = "not checked yet"
        self.downloads = 0

    def clean(self) -> int:
        """Delete copies a crash left behind. Only the indexer's own files, named ``vellum-dl-*``."""
        if self.scratch is None or not self.scratch.is_dir():
            return 0
        gone = 0
        for entry in os.scandir(self.scratch):
            if entry.name.startswith(PREFIX) and entry.is_file(follow_symlinks=False):
                try:
                    os.remove(entry.path)
                    gone += 1
                except OSError:
                    pass
        if gone:
            log.info("Deleted %d copies left in %s", gone, self.scratch)
        return gone

    def _why_not(self, size: int = 0) -> str | None:
        if self.scratch is None:
            return "no scratch folder is set (scratch_folder in settings.toml)"
        if self.client is None:
            return "no Dropbox app key is set (dropbox_app_key in settings.toml)"
        if not self.client.signed_in():
            return "the laptop is not signed in to Dropbox (vellum-indexer sign-in)"
        if not self.drive_present(self.scratch):
            return f"the scratch drive {self.scratch.anchor or self.scratch} is not there"
        try:
            self.scratch.mkdir(parents=True, exist_ok=True)
            free = self.disk_usage(self.scratch).free
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
                log.info("Online-only files are downloaded to %s, read, and the copy deleted", self.scratch)
            self.reason = reason
        return reason is None

    def fetch(self, db_path: str, size: int) -> Path:
        """Download one file to the scratch folder. The caller deletes the copy (``done``). Raises ``Unavailable`` or
        ``DropboxError``; either way nothing is left in the scratch folder."""
        if not self.available(size):
            raise Unavailable(self.reason)
        dest = self.scratch / f"{PREFIX}{uuid.uuid4().hex[:12]}{PurePosixPath(db_path).suffix.lower()}"
        try:
            self.client.download(db_path, dest)
        except NotSignedIn as error:
            dest.unlink(missing_ok=True)
            self.available()
            raise Unavailable(str(error)) from None
        except (DropboxError, OSError) as error:
            dest.unlink(missing_ok=True)
            raise DropboxError(str(error)) from None
        self.downloads += 1
        return dest

    @staticmethod
    def done(copy: Path) -> None:
        copy.unlink(missing_ok=True)
