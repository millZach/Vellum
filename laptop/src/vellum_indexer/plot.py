"""Plotting a DWG layout to PDF with AutoCAD's own core console, so the PDF is what AutoCAD prints (ADR-0007, #67).

The plotter is a seam (``Plotter``), as the title block reader is: AutoCAD's console in use, a stand-in in tests.

- AutoCAD never opens the DWG in the project folder. The plotter copies it into a job folder of its own (the
  indexer's work folder on C:, or the scratch drive for a DWG downloaded there) and plots the copy. Nothing is ever
  saved: the plot answers "No" to saving its settings to the page setup, and the console quits without saving.
- **The layout's own page setup first.** ``-PLOT`` with no detailed configuration takes the layout's saved plotter,
  paper, area, scale and plot style, which is what AutoCAD's Plot dialog prints. That is used when the saved plotter
  writes PDFs (a ``.pc3`` with PDF in its name, such as ``DWG To PDF.pc3``), so a saved setup never sends paper to a
  real printer.
- **The fallback.** A layout whose saved plotter is not a PDF one (None, or a printer) is plotted a second time with
  ``DWG To PDF.pc3`` at the layout's paper size, matched to one of that plotter's sheets, with the layout's area, at
  1:1, keeping its plot style. The answer says so. When the paper size matches none of its sheets the plot fails with
  that reason rather than guessing. The Model tab has no layout to plot and AutoCAD asks it other questions, so a
  Model-tab DWG's fallback plots its extents on that sheet with the Model tab's own answers (#87), fitted to the page,
  not to scale (#92): at 1:1 a real Model-tab drawing ran off the sheet. Such a plot is marked ``fitted``, and the Duo
  places it as an NTS sheet.
- **Never waiting on a question out of step.** Should AutoCAD ask something the script did not expect, it cancels the
  ``-PLOT``; the LISP catches that and reports ``FAILED`` and ``END``, and the plotter stops a console still running
  a few seconds after its report's ``END``. The plot then fails at once with a plain reason, and the time limit is
  left for a console that truly hangs.
- **References on the copy.** The copy sits in a job folder, so an xref, raster image or PDF, DWF or DGN underlay saved
  with a relative path (``..\\Xrefs\\base.dwg``) would no longer resolve. Before plotting, the script makes each such
  path absolute against the original DWG's folder, on the copy only (xrefs re-pathed with ``-XREF Path``, images and
  underlays by changing their definition, images then reloaded), and reports every top-level reference and whether it
  was found. The original is never changed, nothing is written beside it, and the copy is never saved. References
  still not found are counted in the answer.
- Everything typed into the console's script comes from the indexer, never from a request: the layout name comes
  from the title block the indexer read, and is refused if it holds a quote, a backslash or a control character (all of
  which AutoCAD forbids in a layout name anyway); the original's folder is the index's own path, written with forward
  slashes; and the output path is the plotter's own job folder.
"""

from __future__ import annotations

import contextlib
import hashlib
import logging
import re
import shutil
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from typing import Protocol

from vellum_indexer.dwg import BELOW_NORMAL_PRIORITY_CLASS, CREATE_NO_WINDOW, one_line

FALLBACK_DEVICE = "DWG To PDF.pc3"
OUT_OF_STEP = "AutoCAD stopped at a question the laptop didn't expect while plotting"

log = logging.getLogger("vellum_indexer")


class PlotError(Exception):
    """A plot that could not be made. The message is the answer's reason, in plain words."""


@dataclass
class PlotResult:
    pdf: bytes
    page_setup: str  # "saved" (the layout's own) or "fallback" (DWG To PDF at its paper size)
    device: str  # the plotter the layout has saved
    media: str  # the paper it was plotted on, as AutoCAD names it
    layout: str = ""  # the layout plotted, as AutoCAD names it (the saved one, for a request with no layout)
    references: int = 0  # top-level xrefs, images and underlays
    missing: int = 0  # of those, how many couldn't be found
    fitted: bool = False  # plotted to fit the page, not to scale (the Model tab's fallback, #92)


class Plotter(Protocol):
    id: str

    def plot(self, dwg: Path, layout: str | None, work: Path | None = None,
             origin: Path | None = None) -> PlotResult: ...


class NoPlotter:
    id = "none"

    def plot(self, dwg: Path, layout: str | None, work: Path | None = None,
             origin: Path | None = None) -> PlotResult:
        raise PlotError("AutoCAD isn't installed on the laptop")


# --- DWG To PDF's sheets, for the fallback ---------------------------------------------------------------------------

# (name as DWG To PDF.pc3 lists it, short side mm, long side mm, paper units for -PLOT)
DWG_TO_PDF_SHEETS = [
    ("ANSI full bleed A (8.50 x 11.00 Inches)", 215.9, 279.4, "Inches"),
    ("ANSI full bleed B (11.00 x 17.00 Inches)", 279.4, 431.8, "Inches"),
    ("ANSI full bleed C (17.00 x 22.00 Inches)", 431.8, 558.8, "Inches"),
    ("ANSI full bleed D (22.00 x 34.00 Inches)", 558.8, 863.6, "Inches"),
    ("ANSI full bleed E (34.00 x 44.00 Inches)", 863.6, 1117.6, "Inches"),
    ("ARCH full bleed A (9.00 x 12.00 Inches)", 228.6, 304.8, "Inches"),
    ("ARCH full bleed B (12.00 x 18.00 Inches)", 304.8, 457.2, "Inches"),
    ("ARCH full bleed C (18.00 x 24.00 Inches)", 457.2, 609.6, "Inches"),
    ("ARCH full bleed D (24.00 x 36.00 Inches)", 609.6, 914.4, "Inches"),
    ("ARCH full bleed E1 (30.00 x 42.00 Inches)", 762.0, 1066.8, "Inches"),
    ("ARCH full bleed E (36.00 x 48.00 Inches)", 914.4, 1219.2, "Inches"),
    ("ISO full bleed A4 (210.00 x 297.00 MM)", 210.0, 297.0, "Millimeters"),
    ("ISO full bleed A3 (297.00 x 420.00 MM)", 297.0, 420.0, "Millimeters"),
    ("ISO full bleed A2 (420.00 x 594.00 MM)", 420.0, 594.0, "Millimeters"),
    ("ISO full bleed A1 (594.00 x 841.00 MM)", 594.0, 841.0, "Millimeters"),
    ("ISO full bleed A0 (841.00 x 1189.00 MM)", 841.0, 1189.0, "Millimeters"),
]
SHEET_MATCH_MM = 2.0


def fallback_sheet(width_mm: float, height_mm: float) -> tuple[str, str] | None:
    """DWG To PDF's sheet for a layout's paper size (either way round, within 2 mm), and its units; else None."""
    short, long = sorted((width_mm, height_mm))
    for name, s, n, units in DWG_TO_PDF_SHEETS:
        if abs(short - s) <= SHEET_MATCH_MM and abs(long - n) <= SHEET_MATCH_MM:
            return name, units
    return None


def is_pdf_device(device: str) -> bool:
    """A saved plotter that writes a PDF file: a .pc3 with PDF in its name. Anything else could be a real printer."""
    d = device.strip().lower()
    return d.endswith(".pc3") and "pdf" in d


def is_model(layout: str | None) -> bool:
    """Whether a layout is the Model tab, which AutoCAD's -PLOT asks a sequence of its own for."""
    return (layout or "").strip().lower() == "model"


def fallback_reason(layout: str | None) -> str:
    """The answer's reason for a plot made with DWG To PDF because the layout's own page setup doesn't plot to PDF."""
    if is_model(layout):
        return ("the Model tab has no page setup that plots to PDF, so its extents were plotted with DWG To PDF to fit "
                "the page, not to scale")
    return "the layout has no page setup that plots to PDF, so it was plotted with DWG To PDF at its paper size"


def landscape(width_mm: float, height_mm: float, rotation: int) -> bool:
    """Whether the layout prints landscape: its paper wider than tall, unless turned a quarter (rotation 1 or 3)."""
    return (width_mm > height_mm) != (rotation in (1, 3))


# --- The script --------------------------------------------------------------------------------------------------

# AutoLISP typed into the script, as the title block dump is (dwg.py): nothing is loaded, so SECURELOAD never asks.
# (vellum-plot LAYOUT OUT INFO MODE SHEET UNITS ORIENT FOLDER): LAYOUT "" plots the layout the DWG was saved on. It
# writes to INFO the layout's saved setup ("SETUP", name, plotter, paper, width mm, height mm, rotation; the layout's
# name is the group 1 after its AcDbLayout marker, the first group 1 being its page setup's name), makes relative
# reference paths absolute against FOLDER (the original DWG's folder) and reports each reference ("REF", kind, path,
# 1 found or 0 not), then either plots and writes "PLOTTED", or writes "UNUSABLE" (mode "saved" and its plotter is not
# a PDF one) or "NOLAYOUT", then END. MODE "saved" takes the layout's own page setup; "fallback" types a paper layout's
# detailed -PLOT answers and "model" the Model tab's, which AutoCAD 2026 asks differently (#87), its extents at scale
# Fit (#92). A -PLOT AutoCAD
# cancels ("; error: Function cancelled") lands in vellum-plot's *error* handler, which writes "FAILED" with AutoCAD's
# message and END; one still asking when its answers run out (CMDACTIVE) writes "FAILED" and is cancelled with an
# empty (command). Either way "PLOTTED" is never written for a plot that didn't finish.
#
# Why a plain (command ...) and no catch around it: AutoCAD 2026's core console refuses (command ...) called inside
# vl-catch-all-apply, and inside *error*, failing every plot with "bad order function: COMMAND" (the real console
# on made-up drawings, #87). So -PLOT runs as a plain (command ...), the form the saved pass had already plotted with,
# the cancel is caught by *error*, and *error* calls no command at all: it only writes the report and closes it. A
# reference is relative unless it starts with a
# drive (``C:``), a backslash or a slash; nested xrefs (``A|B``) resolve from their parent's path, so only top-level
# ones are changed.
PLOT_FORMS = [
    r"""(defun vellum-pclean (s)
      (while (vl-string-search "\t" s) (setq s (vl-string-subst " " "\t" s)))
      (while (vl-string-search "\n" s) (setq s (vl-string-subst " " "\n" s)))
      s)""",
    r"""(defun vellum-abs (p folder / c)
      (setq c (substr p 1 1))
      (cond ((= p "") p)
            ((= (substr p 2 1) ":") p)
            ((or (= c "\\") (= c "/")) p)
            (T (strcat folder "/" p))))""",
    r"""(defun vellum-refs (folder f / b n p a d e img)
      (setq b (tblnext "BLOCK" T))
      (while b
        (if (and (= 4 (logand 4 (cdr (assoc 70 b)))) (not (vl-string-search "|" (cdr (assoc 2 b)))))
          (progn
            (setq n (cdr (assoc 2 b)) p (cdr (assoc 1 b)) a (vellum-abs p folder))
            (if (/= a p) (command "_.-XREF" "_P" n a))
            (write-line (strcat "REF\txref\t" (vellum-pclean a) "\t"
                                (if (= 32 (logand 32 (cdr (assoc 70 (tblsearch "BLOCK" n))))) "1" "0")) f)))
        (setq b (tblnext "BLOCK")))
      (foreach k '(("ACAD_IMAGE_DICT" . "image") ("ACAD_PDFDEFINITIONS" . "pdf") ("ACAD_DWFDEFINITIONS" . "dwf")
                   ("ACAD_DGNDEFINITIONS" . "dgn"))
        (if (setq d (dictsearch (namedobjdict) (car k)))
          (foreach g d
            (if (= 350 (car g))
              (progn
                (setq e (entget (cdr g)) p (cdr (assoc 1 e)))
                (if p
                  (progn
                    (setq a (vellum-abs p folder))
                    (if (/= a p)
                      (progn (entmod (subst (cons 1 a) (assoc 1 e) e)) (if (= (cdr k) "image") (setq img T))))
                    (write-line (strcat "REF\t" (cdr k) "\t" (vellum-pclean a) "\t" (if (findfile a) "1" "0"))
                                f))))))))
      (if img (command "_.-IMAGE" "_R" "*"))
      (princ))""",
    r"""(defun vellum-plot-done (f)
      (if (= 1 (logand 1 (getvar "CMDACTIVE")))
        (progn (write-line "FAILED\tstill asking when the answers ran out" f) (command))
        (write-line "PLOTTED" f)))""",
    r"""(defun vellum-plot (name out info mode sheet units orient folder / f d e dev *error*)
      (setq *error* (lambda (msg)
                      (if f (progn (write-line (strcat "FAILED\t" (vellum-pclean msg)) f) (write-line "END" f)
                                   (close f) (setq f nil)))
                      (princ)))
      (setq f (vl-catch-all-apply 'open (list info "w" "utf8")))
      (if (or (null f) (vl-catch-all-error-p f)) (setq f (open info "w")))
      (if (= name "") (setq name (getvar "CTAB")))
      (setq d (dictsearch (namedobjdict) "ACAD_LAYOUT"))
      (setq e (if d (dictsearch (cdr (assoc -1 d)) name)))
      (if (null e)
        (write-line "NOLAYOUT" f)
        (progn
          (setq name (cdr (assoc 1 (member '(100 . "AcDbLayout") e))) dev (cdr (assoc 2 e)))
          (if (null dev) (setq dev ""))
          (write-line (strcat "SETUP\t" name "\t" dev "\t" (if (cdr (assoc 4 e)) (cdr (assoc 4 e)) "") "\t"
                              (rtos (cdr (assoc 44 e)) 2 2) "\t" (rtos (cdr (assoc 45 e)) 2 2) "\t"
                              (itoa (cdr (assoc 73 e)))) f)
          (vellum-refs folder f)
          (cond
            ((= mode "saved")
              (if (and (wcmatch (strcase dev) "*.PC3") (wcmatch (strcase dev) "*PDF*"))
                (progn (command "_.-PLOT" "_N" name "" "" out "_N" "_Y") (vellum-plot-done f))
                (write-line "UNUSABLE" f)))
            ((= mode "model")
              (command "_.-PLOT" "_Y" name "DWG To PDF.pc3" sheet units orient "_N" "_E" "_F" "" "_Y" "" "_Y"
                       "_A" out "_N" "_Y")
              (vellum-plot-done f))
            (T
              (command "_.-PLOT" "_Y" name "DWG To PDF.pc3" sheet units orient "_N" "_L" "1:1" "" "_Y" "" "_Y"
                       "_N" "_N" "_N" out "_N" "_Y")
              (vellum-plot-done f)))))
      (write-line "END" f)
      (close f)
      (setq f nil)
      (princ))""",
]
PLOT_LISP = "\n".join(one_line(f) for f in PLOT_FORMS)

UNSAFE_IN_SCRIPT = re.compile(r'["\\\x00-\x1f\x7f]')


def lisp_string(text: str) -> str:
    """A LISP string literal for text the indexer chose. Quotes, backslashes and control characters are refused, not
    escaped: none can be in a layout name, and a line break in a script is Enter."""
    if UNSAFE_IN_SCRIPT.search(text):
        raise PlotError("the layout's name can't be typed into AutoCAD")
    return f'"{text}"'


def plot_script(layout: str | None, out: Path, info: Path, mode: str = "saved", sheet: str = "",
                units: str = "Inches", orient: str = "Landscape", folder: Path | None = None) -> str:
    """The .scr the console runs: define the plot, run it on the layout, quit without saving. ``folder`` is the
    original DWG's folder, against which relative references are made absolute."""
    origin = folder.as_posix().rstrip("/") if folder is not None else ""
    if UNSAFE_IN_SCRIPT.search(origin):
        raise PlotError("the DWG's folder can't be typed into AutoCAD")
    call = "(vellum-plot {})".format(" ".join(lisp_string(a) for a in (
        layout or "", out.as_posix(), info.as_posix(), mode, sheet, f"_{units[0]}", f"_{orient[0]}", origin)))
    return "\n".join([PLOT_LISP, call, "_.QUIT", "_Y", ""])


@dataclass
class SavedSetup:
    layout: str
    device: str
    media: str
    width_mm: float
    height_mm: float
    rotation: int


@dataclass
class Reference:
    kind: str  # "xref", "image", "pdf", "dwf" or "dgn"
    path: str  # as the copy has it after the script: absolute when it was relative
    found: bool


def parse_info(text: str) -> tuple[SavedSetup | None, str, list[Reference]]:
    """The plot's report: the layout's saved setup, how it ended ("PLOTTED", "UNUSABLE", "NOLAYOUT", or "FAILED" when
    AutoCAD cancelled the -PLOT), and the references it found."""
    setup, outcome, complete = None, "", False
    refs: list[Reference] = []
    for line in text.splitlines():
        parts = line.rstrip("\r").split("\t")
        if parts[0] == "REF" and len(parts) >= 4:
            refs.append(Reference(parts[1], parts[2], parts[3].strip() == "1"))
            continue
        if parts[0] == "SETUP" and len(parts) >= 7:
            try:
                setup = SavedSetup(parts[1], parts[2], parts[3], float(parts[4]), float(parts[5]), int(parts[6]))
            except ValueError:
                setup = None
        elif parts[0] in ("PLOTTED", "UNUSABLE", "NOLAYOUT", "FAILED"):
            outcome = parts[0]
        elif parts[0] == "END":
            complete = True
    if not complete:
        outcome = ""
    return setup, outcome, refs


class AccoreconsolePlotter:
    """Plots through AutoCAD's core console, on a copy of the DWG, at below-normal priority, with a time limit. A
    console that has written its report's END but not quit ``after_end`` seconds later is stopped."""

    id = "accoreconsole-plot-1"
    model_mode = "model"  # the script's mode for the Model tab's fallback (its own -PLOT answers)
    poll = 0.25  # seconds between looks at the report while the console runs

    def __init__(self, command: list[str], work: Path, timeout: float = 300.0, after_end: float = 5.0):
        self.command = command
        self.work = work
        self.timeout = timeout
        self.after_end = after_end

    def plot(self, dwg: Path, layout: str | None, work: Path | None = None,
             origin: Path | None = None) -> PlotResult:
        """``origin`` is the original DWG's folder (for an online-only DWG, its folder in Dropbox, not the scratch
        copy's), against which relative references are made absolute."""
        if layout is not None:
            lisp_string(layout)  # refused before AutoCAD starts
        origin = origin or dwg.parent
        job = (work or self.work) / f"plot-{uuid.uuid4().hex[:12]}"
        job.mkdir(parents=True, exist_ok=True)
        try:
            copy = job / "drawing.dwg"
            try:
                shutil.copyfile(dwg, copy)
            except OSError as error:
                raise PlotError("the DWG couldn't be read") from error
            setup, outcome, pdf, refs = self._run(job, copy, layout, "saved", folder=origin)
            if outcome == "NOLAYOUT":
                raise PlotError("the layout isn't in the DWG any more")
            if setup is None or outcome not in ("PLOTTED", "UNUSABLE"):
                raise PlotError("the DWG couldn't be read")
            if outcome == "PLOTTED":
                if pdf is None:
                    raise PlotError("AutoCAD made no PDF from the layout's page setup")
                return PlotResult(pdf, "saved", setup.device, setup.media, setup.layout, len(refs),
                                  sum(not r.found for r in refs))
            model = is_model(setup.layout)
            sheet = fallback_sheet(setup.width_mm, setup.height_mm)
            if sheet is None:
                raise PlotError(f"{'the Model tab' if model else 'the layout'} has no page setup that plots to PDF, "
                                f"and its paper size ({setup.width_mm:.0f} x {setup.height_mm:.0f} mm) isn't one "
                                "DWG To PDF has")
            orient = "Landscape" if landscape(setup.width_mm, setup.height_mm, setup.rotation) else "Portrait"
            # the Model tab: its extents fitted to the page, with the prompts AutoCAD asks there (#87, #92)
            mode = self.model_mode if model else "fallback"
            _, outcome, pdf, refs = self._run(job, copy, setup.layout, mode, sheet[0], sheet[1], orient,
                                              folder=origin)
            if outcome != "PLOTTED" or pdf is None:
                raise PlotError("AutoCAD made no PDF with DWG To PDF")
            return PlotResult(pdf, "fallback", setup.device, sheet[0], setup.layout, len(refs),
                              sum(not r.found for r in refs), fitted=model)
        finally:
            shutil.rmtree(job, ignore_errors=True)

    def _run(self, job: Path, copy: Path, layout: str | None, mode: str, sheet: str = "", units: str = "Inches",
             orient: str = "Landscape", folder: Path | None = None
             ) -> tuple[SavedSetup | None, str, bytes | None, list[Reference]]:
        out = job / f"{mode}.pdf"
        info = job / f"{mode}.txt"
        script = job / f"{mode}.scr"
        script.write_text(plot_script(layout, out, info, mode, sheet, units, orient, folder), encoding="utf-8")
        args = [*self.command, "/i", str(copy), "/s", str(script), "/l", "en-US"]
        flags = BELOW_NORMAL_PRIORITY_CLASS | CREATE_NO_WINDOW if sys.platform == "win32" else 0
        try:
            console = subprocess.Popen(args, cwd=job, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, creationflags=flags)
        except OSError as error:
            raise PlotError("AutoCAD couldn't be started on the laptop") from error
        self._wait(console, info)
        try:
            raw = info.read_bytes()
        except OSError:
            raise PlotError("the DWG couldn't be read") from None
        try:
            text = raw.decode("utf-8-sig")
        except UnicodeDecodeError:
            text = raw.decode("cp1252", errors="replace")
        setup, outcome, refs = parse_info(text)
        if outcome == "FAILED":
            said = next((line.split("\t", 1)[1:] for line in text.splitlines() if line.startswith("FAILED")), [])
            log.warning("AutoCAD cancelled the %s plot: %s", mode, (said or ["no message"])[0].strip())
            raise PlotError(OUT_OF_STEP)
        pdf = None
        if out.is_file():
            data = out.read_bytes()
            if data.startswith(b"%PDF"):
                pdf = data
        return setup, outcome, pdf, refs

    def _wait(self, console: subprocess.Popen, info: Path) -> None:
        """Wait for the console to quit. Once the script's report ends (END), the plot is over whatever AutoCAD does
        next, so a console still running ``after_end`` seconds later is stopped rather than left to the time limit
        (after a cancelled -PLOT the real console sits at its prompt). One that never writes END is stopped at the
        time limit and the plot answered timed out."""
        started = time.monotonic()
        ended = None
        while True:
            try:
                console.wait(timeout=self.poll)
                return
            except subprocess.TimeoutExpired:
                pass
            now = time.monotonic()
            if ended is None and report_ended(info):
                ended = now
            if ended is not None and now - ended >= self.after_end:
                log.info("AutoCAD's console wrote its report but hadn't quit %.0f s later, so it was stopped",
                         self.after_end)
                stop(console)
                return
            if ended is None and now - started >= self.timeout:
                stop(console)
                minutes = self.timeout / 60
                limit = f"{minutes:.0f} minutes" if minutes >= 1 else f"{self.timeout:.0f} seconds"
                raise PlotError(f"timed out: AutoCAD took longer than {limit}, so the plot was stopped")


def report_ended(info: Path) -> bool:
    """Whether the script's report has its END line yet. The report is a few hundred bytes."""
    try:
        return b"END" in info.read_bytes().splitlines()
    except OSError:
        return False


def stop(console: subprocess.Popen) -> None:
    console.kill()
    with contextlib.suppress(subprocess.TimeoutExpired):
        console.wait(timeout=10)


# --- Where a plot goes -------------------------------------------------------------------------------------------

PLOTS_FOLDER = ("Vellum", "Plots")
NO_PROJECT = "No project"
WINDOWS_UNSAFE = re.compile(r'[<>:"/\\|?*\x00-\x1f\x7f]')
RESERVED = {"con", "prn", "aux", "nul", *(f"com{i}" for i in range(10)), *(f"lpt{i}" for i in range(10))}


def safe_part(text: str, limit: int = 60) -> str:
    """One folder or file name part Windows and Dropbox take: no reserved characters or names, no trailing dots or
    spaces, no leading ``~$`` or ``.``, at most ``limit`` characters."""
    cleaned = WINDOWS_UNSAFE.sub("_", text).strip()
    cleaned = cleaned.lstrip(".~$ ")[:limit].rstrip(". ")
    if not cleaned or cleaned.lower().split(".")[0] in RESERVED:
        cleaned = f"_{cleaned}" if cleaned else "_"
    return cleaned


def plot_name(project: str | None, dwg_path: str, layout: str | None, dwg_mtime_ns: int, version: str = "",
              mode: str = "") -> str:
    """The plot's Dropbox path: ``/Vellum/Plots/<project>/<DWG name> - <layout> - <DWG saved, UTC> - <8 hex>.pdf``.

    The project and drawing are recognisable at a glance. The layout keeps two layouts of one DWG apart; the DWG's
    saved time, to the second, is there to read. The 8 hex digits come from the DWG's path, layout and ``version``,
    the SHA-256 of the DWG's bytes: two DWGs of one name in different folders of a project never clash, and nor do two
    versions of one DWG saved within the same second, so a re-plot never overwrites the older plot. ``mode`` is how
    it was plotted when that isn't to scale (``"fit"``, #92), so a fitted re-plot of the DWG version a 1:1 plot was
    made of never takes that plot's name; a plot to scale has none, and keeps the name it always had.
    """
    stem = PurePosixPath(dwg_path).stem
    saved = datetime.fromtimestamp(dwg_mtime_ns / 1e9, UTC).strftime("%Y-%m-%d %H%M%S")
    key = dwg_path.lower() + "#" + (layout or "").lower() + "#" + version + (f"#{mode}" if mode else "")
    tag = hashlib.sha256(key.encode("utf-8")).hexdigest()[:8]
    parts = [safe_part(stem, 80)] + ([safe_part(layout, 40)] if layout else []) + [saved, tag]
    return "/" + "/".join([*PLOTS_FOLDER, safe_part(project or NO_PROJECT, 80), " - ".join(parts) + ".pdf"])


def file_version(path: Path) -> str:
    """The SHA-256 of a file's bytes, read in 1 MB blocks: which version of a DWG a plot is of."""
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while block := f.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()
