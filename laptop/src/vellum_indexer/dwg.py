"""Reading a DWG: its title block attributes (through AutoCAD's own accoreconsole) and the preview bitmap AutoCAD
saves in its header.

The attribute reader is a seam (``TitleBlockReader``): the indexer is handed one, AutoCAD's in use and a fake in
tests, so the tests run without AutoCAD. Every reader returns the same thing, the block inserts that carry
attributes, layout by layout; fields.py turns them into title block fields.

AutoCAD never opens the DWG in the project folder. The reader copies it into the indexer's own work folder on the
laptop and opens the copy, so AutoCAD's lock files (.dwl, .dwl2) and anything else it writes land there, and the
original is only ever read.
"""

from __future__ import annotations

import io
import os
import shutil
import struct
import subprocess
import sys
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from PIL import Image

from vellum_indexer.pdf import fit, png_bytes


@dataclass
class BlockInsert:
    layout: str
    block: str
    attributes: dict[str, str] = field(default_factory=dict)  # tag (as written) -> value


class TitleBlockReader(Protocol):
    # Changing what a reader reads changes its id, so drawings read by an older one are read again.
    id: str

    def read(self, path: Path, work: Path | None = None) -> list[BlockInsert]: ...


class NoReader:
    """No AutoCAD on this laptop: DWGs are listed with their fields from the PDF, or unread."""

    id = "none"

    def read(self, path: Path, work: Path | None = None) -> list[BlockInsert]:
        return []


class ReaderError(Exception):
    pass


# AutoLISP run inside accoreconsole: every block insert with attributes, its layout, block name and each attribute's
# tag and value, one per line, tab-separated. Core console has no ActiveX, so it is plain entget/entnext.
#
# It is typed into the script itself, one form per line, rather than saved as a .lsp file and loaded: AutoCAD's
# SECURELOAD (1 by default) asks before loading a file from a folder it does not trust, the core console cannot answer,
# and Zach's AutoCAD security settings are his. Nothing is loaded, so SECURELOAD never asks.
DUMP_FORMS = [
    r"""(defun vellum-clean (s)
      (while (vl-string-search "\t" s) (setq s (vl-string-subst " " "\t" s)))
      (while (vl-string-search "\n" s) (setq s (vl-string-subst " " "\n" s)))
      s)""",
    # AutoCAD 2021 and later take an encoding; an older one errors on it and writes its ANSI code page instead.
    r"""(defun vellum-dump (out / f ss i e ent a ae)
      (setq f (vl-catch-all-apply 'open (list out "w" "utf8")))
      (if (or (null f) (vl-catch-all-error-p f)) (setq f (open out "w")))
      (if (setq ss (ssget "_X" '((0 . "INSERT") (66 . 1))))
        (progn
          (setq i 0)
          (repeat (sslength ss)
            (setq e (ssname ss i) ent (entget e))
            (write-line (strcat "INSERT\t" (vellum-clean (cdr (assoc 410 ent))) "\t"
                                (vellum-clean (cdr (assoc 2 ent)))) f)
            (setq a (entnext e))
            (while (and a (= "ATTRIB" (cdr (assoc 0 (setq ae (entget a))))))
              (write-line (strcat "ATTRIB\t" (vellum-clean (cdr (assoc 2 ae))) "\t"
                                  (vellum-clean (cdr (assoc 1 ae)))) f)
              (setq a (entnext a)))
            (setq i (1+ i)))))
      (write-line "END" f)
      (close f)
      (princ))""",
]


def one_line(form: str) -> str:
    """A form on one script line: in a script a line break is Enter. The forms hold no string with a run of spaces."""
    return " ".join(form.split())


DUMP_LISP = "\n".join(one_line(f) for f in DUMP_FORMS)


def dump_script(out: Path) -> str:
    """The .scr accoreconsole runs: define the dump, run it, quit without saving."""
    return "\n".join([DUMP_LISP, f'(vellum-dump "{out.as_posix()}")', "_.QUIT", "_Y", ""])


def parse_dump(text: str) -> list[BlockInsert]:
    """The accoreconsole dump, read back. Raises when it has no END line (AutoCAD stopped part way)."""
    inserts: list[BlockInsert] = []
    complete = False
    for line in text.splitlines():
        parts = line.rstrip("\r").split("\t")
        if parts[0] == "INSERT" and len(parts) >= 3:
            inserts.append(BlockInsert(layout=parts[1], block=parts[2]))
        elif parts[0] == "ATTRIB" and len(parts) >= 3 and inserts:
            inserts[-1].attributes.setdefault(parts[1], "\t".join(parts[2:]).strip())
        elif parts[0] == "END":
            complete = True
    if not complete:
        raise ReaderError("the attribute dump is incomplete")
    return inserts


def find_accoreconsole(configured: Path | None = None) -> Path | None:
    if configured:
        return configured if configured.exists() else None
    if sys.platform != "win32":
        return None
    base = Path(os.environ.get("PROGRAMFILES", r"C:\Program Files")) / "Autodesk"
    found = sorted(base.glob("AutoCAD*/accoreconsole.exe"), reverse=True)  # the newest AutoCAD first
    return found[0] if found else None


BELOW_NORMAL_PRIORITY_CLASS = 0x00004000
CREATE_NO_WINDOW = 0x08000000


class AccoreconsoleReader:
    """Title block attributes through AutoCAD's core console, on a copy of the DWG in the work folder."""

    id = "accoreconsole-1"

    def __init__(self, command: list[str], work: Path, timeout: float = 180.0):
        self.command = command  # [accoreconsole.exe] (or a fake in tests)
        self.work = work
        self.timeout = timeout

    def clean(self) -> None:
        """Delete work folders a stop left behind."""
        if self.work.is_dir():
            for entry in os.scandir(self.work):
                if entry.is_dir(follow_symlinks=False):
                    shutil.rmtree(entry.path, ignore_errors=True)

    def read(self, path: Path, work: Path | None = None) -> list[BlockInsert]:
        """``work`` puts the copy somewhere else: a DWG downloaded to the scratch drive is worked on there, never
        copied to C:."""
        job = (work or self.work) / uuid.uuid4().hex[:12]
        job.mkdir(parents=True, exist_ok=True)
        try:
            copy = job / "drawing.dwg"
            shutil.copyfile(path, copy)
            out = job / "attributes.txt"
            script = job / "dump.scr"
            script.write_text(dump_script(out), encoding="utf-8")
            args = [*self.command, "/i", str(copy), "/s", str(script), "/l", "en-US"]
            flags = BELOW_NORMAL_PRIORITY_CLASS | CREATE_NO_WINDOW if sys.platform == "win32" else 0
            try:
                subprocess.run(
                    args,
                    cwd=job,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=self.timeout,
                    creationflags=flags,
                    check=False,
                )
            except subprocess.TimeoutExpired as error:
                raise ReaderError(f"accoreconsole took longer than {self.timeout:.0f} s") from error
            except OSError as error:
                raise ReaderError(f"accoreconsole could not start: {error}") from error
            try:
                raw = out.read_bytes()
            except OSError as error:
                raise ReaderError("accoreconsole wrote no attribute dump") from error
            try:
                text = raw.decode("utf-8-sig")
            except UnicodeDecodeError:
                text = raw.decode("cp1252", errors="replace")
            return parse_dump(text)
        finally:
            shutil.rmtree(job, ignore_errors=True)


# --- The preview AutoCAD saves in a DWG's header ---------------------------------------------------------------------

PREVIEW_SENTINEL = bytes.fromhex("1F256D07D43628289D57CA3F9D44102B")
PREVIEW_HEADER = 1
PREVIEW_BMP = 2
PREVIEW_WMF = 3
PREVIEW_PNG = 6
HEAD_BYTES = 64 * 1024 * 1024  # a preview past this is not read


def read_preview(path: Path) -> bytes | None:
    """The DWG's saved preview as a thumbnail PNG, or None. Reads the header's image pointer (offset 0x0D, R13 and
    later), then the image section it points at: a sentinel, then entries of (code, start, size); code 2 is a BMP
    without its file header, code 6 (AutoCAD 2013 and later) a PNG."""
    try:
        with open(path, "rb") as f:
            head = f.read(0x11)
            if len(head) < 0x11 or not head.startswith(b"AC1"):
                return None
            (seeker,) = struct.unpack_from("<i", head, 0x0D)
            if seeker <= 0 or seeker > HEAD_BYTES:
                return None
            f.seek(seeker)
            section = f.read(16 + 4 + 1)
            if len(section) < 21 or section[:16] != PREVIEW_SENTINEL:
                return None
            count = section[20]
            table = f.read(count * 9)
            entries = [struct.unpack_from("<Bii", table, i * 9) for i in range(len(table) // 9)]
            for wanted in (PREVIEW_PNG, PREVIEW_BMP):
                for code, start, size in entries:
                    if code != wanted or start <= 0 or size <= 0 or size > 16 * 1024 * 1024:
                        continue
                    f.seek(start)
                    data = f.read(size)
                    if len(data) != size:
                        continue
                    image = _open_png(data) if code == PREVIEW_PNG else _open_dib(data)
                    if image is not None:
                        return png_bytes(fit(image))
    except (OSError, struct.error):
        return None
    return None


def _open_png(data: bytes) -> Image.Image | None:
    try:
        image = Image.open(io.BytesIO(data))
        image.load()
        return image
    except Exception:  # noqa: BLE001 - any undecodable preview means no thumbnail
        return None


def _open_dib(data: bytes) -> Image.Image | None:
    """A BMP stored without its 14-byte file header: add one and let Pillow read it."""
    if len(data) < 40:
        return None
    header_size, _, _, _, bits = struct.unpack_from("<IiiHH", data, 0)
    colours = struct.unpack_from("<I", data, 32)[0]
    if bits <= 8 and colours == 0:
        colours = 1 << bits
    offset = 14 + header_size + colours * 4
    file_header = b"BM" + struct.pack("<IHHI", 14 + len(data), 0, 0, offset)
    try:
        image = Image.open(io.BytesIO(file_header + data))
        image.load()
        return image
    except Exception:  # noqa: BLE001
        return None
