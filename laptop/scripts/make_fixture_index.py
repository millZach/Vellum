"""Makes the made-up drawing index in laptop/tests/fixtures/drawing-index, for the indexer's tests and for the Duo's
(#68). Every drawing, project and title block in it is made up here.

usage: python scripts/make_fixture_index.py [out folder]

It builds a made-up Dropbox in a temp folder, runs the indexer over it with a stand-in DWG reader, and copies
Dropbox/Vellum/Index out. The tree has one of each case the Duo shows: a DWG with its plot (paired by plot metadata,
and by name), a DWG with no PDF yet (with its DWG preview as the thumbnail), a vendor PDF with no DWG, an AS NOTED
sheet, an NTS loop drawing, a three-page PDF, a DWG with two PDFs, an online-only PDF listed unread, and a drawing
with no project folder.
"""

from __future__ import annotations

import shutil
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE.parent / "src"), str(HERE.parent / "tests")]

from PIL import Image, ImageDraw  # noqa: E402

from vellum_indexer import files  # noqa: E402
from vellum_indexer.dwg import BlockInsert  # noqa: E402
from vellum_indexer.indexer import Indexer  # noqa: E402
from vellum_indexer.state import State  # noqa: E402

from makers import make_dwg_with_preview, title_block_pdf, touch  # noqa: E402

OUT = HERE.parent / "tests" / "fixtures" / "drawing-index"
UPDATED = datetime(2026, 11, 7, 12, 0, tzinfo=UTC)

SCHOOL = "Projects/Made-up School Addition"
PLANT = "Projects/Made-up Plant Upgrade"
FT = '1/4" = 1\'-0"'

# DWG -> its made-up title block attributes
DWGS = {
    f"{SCHOOL}/Mechanical/CAD/M-101.dwg": {"DWG_NO": "M-101", "TITLE": "First floor HVAC plan", "REV": "C",
                                           "SCALE": FT, "DATE": "2026-10-12"},
    f"{SCHOOL}/Mechanical/CAD/M-501.dwg": {"DWG_NO": "M-501", "TITLE": "Mechanical details", "REV": "B",
                                           "SCALE": "AS NOTED", "DATE": "2026-10-01"},
    f"{SCHOOL}/Mechanical/CAD/M-102.dwg": {"DWG_NO": "M-102", "TITLE_LINE_1": "Second floor", "TITLE_LINE_2": "HVAC plan",
                                           "REV": "A", "SCALE": FT, "DATE": "2026-11-02"},
    f"{PLANT}/Electrical/E-201.dwg": {"DWGNO": "E-201", "TITLE": "Boiler room power plan", "REV": "A", "SCALE": FT,
                                      "DATE": "2026-09-14"},
    f"{PLANT}/Instrumentation/I-301.dwg": {"DWGNO": "I-301", "TITLE": "Loop diagram FT-101", "REV": "0",
                                           "SCALE": "NTS", "DATE": "2026-08-30"},
    f"{PLANT}/Instrumentation/I-302.dwg": {"DWGNO": "I-302", "TITLE": "Loop diagram LT-102", "REV": "0",
                                           "SCALE": "NTS", "DATE": "2026-08-30"},
}
# PDF -> (title block text fields, plot metadata title, paper inches, pages)
PDFS = {
    f"{SCHOOL}/Mechanical/PDF/Issued set 2026-10-12.pdf": (
        dict(number="M-101", title="First floor HVAC plan", rev="C", scale=FT, date="2026-10-12"),
        "M-101-Layout1", (36, 24), 1),
    f"{SCHOOL}/Mechanical/PDF/M-501.pdf": (
        dict(number="M-501", title="Mechanical details", rev="B", scale="AS NOTED", date="2026-10-01"),
        None, (36, 24), 3),
    f"{PLANT}/Instrumentation/PDF/I-301.pdf": (
        dict(number="I-301", title="Loop diagram FT-101", rev="0", scale="NTS", date="2026-08-30"),
        None, (17, 11), 1),
    f"{PLANT}/Instrumentation/PDF/I-301 - Rev 0 issued.pdf": (
        dict(number="I-301", title="Loop diagram FT-101", rev="0", scale="NTS", date="2026-08-01"),
        None, (17, 11), 1),
    f"{PLANT}/Vendor/V-12 Pump skid GA.pdf": (
        dict(number="V-12", title="Pump skid general arrangement", rev="2", scale="1:20", date="2026-09-30"),
        None, (17, 11), 1),
    f"{PLANT}/Instrumentation/PDF/I-302.pdf": (dict(), None, (17, 11), 1),  # online-only on the laptop
    "Made-up loose sketch.pdf": (dict(title="Made-up loose sketch"), None, (11, 8.5), 1),
}
ONLINE_ONLY = {"I-302.pdf"}


class FixtureReader:
    id = "fixture-1"

    def __init__(self, root: Path):
        self.root = root

    def read(self, path: Path) -> list[BlockInsert]:
        return [BlockInsert("Layout1", "TITLEBLOCK", DWGS[files.dropbox_path(self.root, path)[1:]])]


def preview(seed: int) -> Image.Image:
    image = Image.new("RGB", (180, 120), "black")
    draw = ImageDraw.Draw(image)
    draw.rectangle((8, 8, 172, 112), outline="white", width=2)
    draw.line((20, 100, 60 + seed * 15, 30), fill="yellow", width=3)
    return image


def online_only(path: Path, st) -> int:
    return files.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS if path.name in ONLINE_ONLY else files.attributes_of(st)


def make(out: Path = OUT) -> Path:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        root = tmp / "Dropbox"
        for i, rel in enumerate(DWGS):
            make_dwg_with_preview(root / rel, preview(i))
        for i, (rel, (fields, meta, inches, pages)) in enumerate(PDFS.items()):
            title_block_pdf(root / rel, title_meta=meta, inches=inches, pages=pages, mark=i, **fields)
        for i, f in enumerate(sorted(root.rglob("*"), key=lambda p: p.as_posix().lower())):
            if f.is_file():
                touch(f, 1_790_000_000 + i * 3600)
        state = State(tmp / "state.sqlite")
        indexer = Indexer(root, state, dwg_reader=FixtureReader(root), attributes=online_only)
        indexer.writer.now = lambda: UPDATED
        indexer.scan()
        state.close()
        if out.exists():
            shutil.rmtree(out)
        shutil.copytree(root / "Vellum" / "Index", out)
    return out


if __name__ == "__main__":
    print(make(Path(sys.argv[1]) if len(sys.argv) > 1 else OUT))
