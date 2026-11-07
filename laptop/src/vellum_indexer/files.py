"""Finding the drawings in the Dropbox folder: skip rules, Dropbox paths, and online-only files.

Nothing here opens a file. A file's size, modified time and attributes come from the directory listing
(``os.scandir``; on Windows the attributes are in the listing itself), which never pulls an online-only file down.
"""

from __future__ import annotations

import fnmatch
import os
import stat as stat_module
from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

KINDS = {".dwg": "dwg", ".pdf": "pdf"}

# Windows cloud files (Dropbox's online-only placeholders). Opening such a file downloads it.
FILE_ATTRIBUTE_OFFLINE = 0x1000
FILE_ATTRIBUTE_RECALL_ON_OPEN = 0x40000
FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x400000
ONLINE_ONLY_ATTRIBUTES = FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_RECALL_ON_OPEN | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS

# Folders Dropbox keeps for itself, at any depth.
SKIPPED_FOLDER_NAMES = {".dropbox.cache", ".dropbox", "$recycle.bin", "system volume information"}
# Temp, lock and backup files AutoCAD and Office leave beside drawings.
SKIPPED_FILE_GLOBS = ["~$*", "*.dwl", "*.dwl2", "*.bak", "*.sv$", "*.tmp", ".~*"]
# Vellum's own folder: canvases, symbols and the index itself.
VELLUM_FOLDER = "/vellum"


def dropbox_path(root: Path, path: Path) -> str:
    """The path as the Duo's Dropbox client names it: ``/Projects/Plant/M-101.dwg``."""
    rel = os.path.relpath(path, root).replace(os.sep, "/")
    return "/" if rel == "." else "/" + rel


def local_path(root: Path, db_path: str) -> Path:
    return root.joinpath(*[p for p in db_path.split("/") if p])


def parent_folder(db_path: str) -> str:
    parent = str(PurePosixPath(db_path).parent)
    return parent


def key(db_path: str) -> str:
    """Dropbox paths are case-insensitive, and so is the laptop's disk."""
    return db_path.lower()


class SkipRules:
    """What the scan leaves out: Dropbox/Vellum, Dropbox's caches, temp and lock files, and settings excludes."""

    def __init__(self, exclude: list[str] | None = None):
        self.exclude = [g.lower() for g in (exclude or [])]

    def skips_folder(self, db_path: str) -> bool:
        lower = db_path.lower()
        if lower == VELLUM_FOLDER or lower.startswith(VELLUM_FOLDER + "/"):
            return True
        if PurePosixPath(lower).name in SKIPPED_FOLDER_NAMES:
            return True
        return self._excluded(lower) or self._excluded(lower + "/")

    def skips_file(self, db_path: str) -> bool:
        lower = db_path.lower()
        name = PurePosixPath(lower).name
        if any(fnmatch.fnmatchcase(name, g) for g in SKIPPED_FILE_GLOBS):
            return True
        parts = lower.split("/")
        for i in range(2, len(parts)):
            if self.skips_folder("/".join(parts[:i])):
                return True
        return self._excluded(lower)

    def indexes(self, db_path: str) -> bool:
        """A DWG or PDF the scan reads."""
        return kind_of(db_path) is not None and not self.skips_file(db_path)

    def _excluded(self, lower: str) -> bool:
        for glob in self.exclude:
            if fnmatch.fnmatchcase(lower, glob):
                return True
            # "/a/**" also names the folder "/a" itself.
            if glob.endswith("/**") and (lower == glob[:-3] or lower.startswith(glob[:-2])):
                return True
        return False


def kind_of(db_path: str) -> str | None:
    return KINDS.get(PurePosixPath(db_path.lower()).suffix)


@dataclass(frozen=True)
class FileFacts:
    """What the listing says about a file. ``online_only``: a Dropbox placeholder, not to be opened."""

    path: str
    size: int
    mtime_ns: int
    online_only: bool


def attributes_of(st: os.stat_result) -> int:
    return getattr(st, "st_file_attributes", 0)


# A seam so tests can fake Windows' online-only attributes on any platform.
AttributeReader = Callable[[Path, os.stat_result], int]


def default_attributes(path: Path, st: os.stat_result) -> int:
    return attributes_of(st)


def is_online_only(attributes: int) -> bool:
    return bool(attributes & ONLINE_ONLY_ATTRIBUTES)


def facts_for(
    root: Path, path: Path, st: os.stat_result, attributes: AttributeReader = default_attributes
) -> FileFacts:
    return FileFacts(
        path=dropbox_path(root, path),
        size=st.st_size,
        mtime_ns=st.st_mtime_ns,
        online_only=is_online_only(attributes(path, st)),
    )


def listing(folder: Path) -> dict[str, os.DirEntry] | None:
    """A folder's entries by lower-case name, or None when it could not be listed (gone, or refused for a moment)."""
    try:
        with os.scandir(folder) as entries:
            return {entry.name.lower(): entry for entry in entries}
    except OSError:
        return None


def look_up(
    root: Path, db_paths: Iterable[str], attributes: AttributeReader = default_attributes
) -> tuple[dict[str, FileFacts | None], set[str]]:
    """Each path's facts, or None when its folder was listed and it is not there, read from its folder's listing
    rather than ``os.stat``: on Windows ``os.stat`` opens a handle to the file, and the listing never touches it.
    Also the folders that could not be listed: their paths are left out, since "not listed" is not "gone"."""
    by_folder: dict[str, list[str]] = {}
    for db in db_paths:
        by_folder.setdefault(parent_folder(db), []).append(db)
    found: dict[str, FileFacts | None] = {}
    unlisted: set[str] = set()
    for folder, wanted in by_folder.items():
        listed = listing(local_path(root, folder))
        if listed is None:
            if folder_state(root, folder) == "gone":
                found.update({db: None for db in wanted})
            else:
                unlisted.add(folder)
            continue
        for db in wanted:
            entry = listed.get(PurePosixPath(db).name.lower())
            found[db] = None
            if entry is None:
                continue
            try:
                if entry.is_file(follow_symlinks=False):
                    st = entry.stat(follow_symlinks=False)
                    if stat_module.S_ISREG(st.st_mode):
                        found[db] = facts_for(root, Path(entry.path), st, attributes)
            except OSError:
                found.pop(db)
                unlisted.add(folder)
    return found, unlisted


def folder_state(root: Path, db_folder: str) -> str:
    """"folder", "gone" (its parent was listed and it is not there, or is not a folder), or "unknown"."""
    if db_folder == "/":
        return "folder"
    parent = listing(local_path(root, parent_folder(db_folder)))
    if parent is None:
        return "unknown"
    entry = parent.get(PurePosixPath(db_folder).name.lower())
    try:
        return "folder" if entry is not None and entry.is_dir(follow_symlinks=False) else "gone"
    except OSError:
        return "unknown"


def walk(
    root: Path,
    rules: SkipRules,
    start: str = "/",
    attributes: AttributeReader = default_attributes,
    on_error: Callable[[Path, OSError], None] | None = None,
) -> Iterator[FileFacts]:
    """Every DWG and PDF under ``start`` that the rules keep, without opening any of them."""
    stack = [local_path(root, start)]
    while stack:
        folder = stack.pop()
        try:
            with os.scandir(folder) as entries:
                listed = sorted(entries, key=lambda e: e.name.lower())
        except OSError as error:
            if on_error:
                on_error(folder, error)
            continue
        subfolders = []
        for entry in listed:
            path = Path(entry.path)
            db = dropbox_path(root, path)
            try:
                if entry.is_dir(follow_symlinks=False):
                    if not rules.skips_folder(db):
                        subfolders.append(path)
                    continue
                if not entry.is_file(follow_symlinks=False) or not rules.indexes(db):
                    continue
                st = entry.stat(follow_symlinks=False)
            except OSError as error:
                if on_error:
                    on_error(path, error)
                continue
            yield facts_for(root, path, st, attributes)
        stack.extend(reversed(subfolders))
