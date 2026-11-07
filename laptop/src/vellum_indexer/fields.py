"""Title block fields (drawing number, title, revision, scale, date) from a DWG's attributes, from a PDF's text, or
the drawing number from the file name.

The DWG comes first: each paper space layout's title block is the insert in it whose attribute tags name the most
fields, so a DWG with several layouts has a title block (a sheet) per layout; Model space counts only when no layout
has one. A PDF's first page text is read by its labels ("DWG NO",
"REV", "SCALE", "DATE", "TITLE"), the value after the label on the same line or on the next. Where neither gives a
drawing number, a file name that looks like one (``M-101``, ``E201A``) is used.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from dataclasses import asdict, dataclass

from vellum_indexer.dwg import BlockInsert

FIELDS = ("number", "title", "revision", "scale", "date")


@dataclass
class TitleBlock:
    number: str | None = None
    title: str | None = None
    revision: str | None = None
    scale: str | None = None
    date: str | None = None

    def any(self) -> bool:
        return any(getattr(self, f) for f in FIELDS)

    def as_dict(self) -> dict[str, str | None]:
        return asdict(self)

    @staticmethod
    def from_dict(data: dict | None) -> TitleBlock:
        data = data or {}
        return TitleBlock(**{f: data.get(f) for f in FIELDS})

    def filled_from(self, other: TitleBlock) -> TitleBlock:
        return TitleBlock(**{f: getattr(self, f) or getattr(other, f) for f in FIELDS})


def norm_tag(tag: str) -> str:
    return re.sub(r"[^A-Z0-9]", "", tag.upper())


DEFAULT_TAGS: dict[str, list[str]] = {
    "number": [
        "DWGNO", "DWGNUM", "DWGNUMBER", "DRAWINGNO", "DRAWINGNUM", "DRAWINGNUMBER", "DWG", "DWGNBR",
        "SHEETNO", "SHEETNUMBER", "SHTNO", "DOCNO", "DOCUMENTNO", "DOCUMENTNUMBER", "NUMBER",
    ],
    "title": ["TITLE", "DWGTITLE", "DRAWINGTITLE", "SHEETTITLE", "SHTTITLE", "DESCRIPTION"],
    "revision": ["REV", "REVISION", "REVNO", "CURRENTREV", "DWGREV", "LATESTREV", "REVLEVEL"],
    "scale": ["SCALE", "DWGSCALE", "DRAWINGSCALE", "PLOTSCALE", "SHEETSCALE"],
    "date": ["DATE", "DWGDATE", "DRAWINGDATE", "ISSUEDATE", "PLOTDATE"],
}
# Titles split over lines: TITLE1, TITLE2... or TITLE_LINE_1..., joined in order.
TITLE_LINE = re.compile(r"^(?:DWG|DRAWING|SHEET)?TITLE(?:LINE)?(\d)$")


class TagMap:
    def __init__(self, extra: dict[str, list[str]] | None = None):
        self.tags: dict[str, str] = {}
        for name, tags in DEFAULT_TAGS.items():
            for t in tags:
                self.tags.setdefault(norm_tag(t), name)
        for name, tags in (extra or {}).items():
            if name in FIELDS:
                for t in tags:
                    self.tags[norm_tag(t)] = name

    def field_of(self, tag: str) -> str | None:
        return self.tags.get(norm_tag(tag))

    def score(self, insert: BlockInsert) -> int:
        named = {self.field_of(t) for t in insert.attributes} | {
            "title" for t in insert.attributes if TITLE_LINE.match(norm_tag(t))
        }
        return len(named - {None})


def clean(value: str | None) -> str | None:
    if value is None:
        return None
    value = re.sub(r"\s+", " ", value).strip()
    # AutoCAD shows an unevaluated field as ####, and blank attributes are often a dash or underscores.
    if not value or set(value) <= set("#-_.?"):
        return None
    return value


def _block_of(insert: BlockInsert, tags: TagMap) -> TitleBlock:
    block = TitleBlock()
    title_lines: dict[int, str] = {}
    for tag, raw in insert.attributes.items():
        value = clean(raw)
        if value is None:
            continue
        line = TITLE_LINE.match(norm_tag(tag))
        if line:
            title_lines[int(line.group(1))] = value
            continue
        name = tags.field_of(tag)
        if name and getattr(block, name) is None:
            setattr(block, name, value)
    if block.title is None and title_lines:
        block.title = " ".join(title_lines[k] for k in sorted(title_lines))
    return block


@dataclass
class Sheet:
    """One layout's title block: a DWG with several layouts, each its own titled sheet, has one per layout."""

    layout: str
    block: TitleBlock

    def as_dict(self) -> dict:
        return {"layout": self.layout, **self.block.as_dict()}

    @staticmethod
    def from_dict(data: dict) -> Sheet:
        return Sheet(data.get("layout") or "", TitleBlock.from_dict(data))


def sheets_from_attributes(inserts: Iterable[BlockInsert], tags: TagMap | None = None) -> list[Sheet]:
    """Each layout's title block, in the order the layouts were met: in each layout the insert whose tags name the
    most fields (the first such). Model space counts only when no paper space layout has a title block."""
    tags = tags or TagMap()
    best: dict[str, tuple[int, int, BlockInsert]] = {}
    for i, insert in enumerate(inserts):
        score = tags.score(insert)
        if score <= 0:
            continue
        held = best.get(insert.layout)
        if held is None or score > held[0]:
            best[insert.layout] = (score, held[1] if held else i, insert)
    paper = {k: v for k, v in best.items() if k.lower() != "model"}
    chosen = paper or best
    ordered = sorted(chosen.items(), key=lambda kv: kv[1][1])
    return [Sheet(layout, _block_of(insert, tags)) for layout, (_, _, insert) in ordered]


def from_attributes(inserts: Iterable[BlockInsert], tags: TagMap | None = None) -> TitleBlock:
    """The first sheet's title block (a one-layout DWG's only one)."""
    sheets = sheets_from_attributes(inserts, tags)
    return sheets[0].block if sheets else TitleBlock()


# --- A PDF's text ----------------------------------------------------------------------------------------------------

LABELS = {
    "number": re.compile(
        r"^(?:DWG|DRAWING|DRWG|SHEET|SHT|DOC(?:UMENT)?)\.?\s*(?:NO|NUM|NUMBER|NBR|#)\b\.?\s*[:#]?\s*(.*)$", re.I
    ),
    "revision": re.compile(r"^REV(?:ISION)?\b\.?\s*(?:NO\b\.?|LEVEL\b)?\s*:?\s*(.*)$", re.I),
    "scale": re.compile(r"^(?:DWG\.?\s+|DRAWING\s+|PLOT\s+)?SCALE\b\s*:?\s*(.*)$", re.I),
    "date": re.compile(r"^(?:DWG\.?\s+|DRAWING\s+|ISSUE\s+)?DATE\b\s*:?\s*(.*)$", re.I),
    "title": re.compile(r"^(?:DWG\.?\s+|DRAWING\s+|SHEET\s+)?TITLE\b\s*:?\s*(.*)$", re.I),
}
NUMBER_VALUE = re.compile(r"^[A-Z0-9][A-Z0-9.\-_/]{0,24}$", re.I)
REVISION_VALUE = re.compile(r"^[A-Z0-9]{1,3}$", re.I)
SCALE_VALUE = re.compile(r"=|\d\s*:\s*\d|\bNTS\b|NOT TO SCALE|AS NOTED|AS SHOWN|\bNONE\b|\bFULL\b", re.I)
DATE_VALUE = re.compile(r"\d")
FILE_NUMBER = re.compile(r"^[A-Z]{1,4}[-_ ]?\d{1,5}(?:[.-]\d{1,3})?[A-Z]?$", re.I)


def _valid(name: str, value: str) -> str | None:
    value = value.strip()
    if not value:
        return None
    if name == "number":
        token = value.split()[0]
        return token if NUMBER_VALUE.match(token) and re.search(r"\d", token) else None
    if name == "revision":
        token = value.split()[0]
        return token.upper() if REVISION_VALUE.match(token) else None
    if name == "scale":
        return value if SCALE_VALUE.search(value) and len(value) <= 40 else None
    if name == "date":
        return value if DATE_VALUE.search(value) and len(value) <= 24 else None
    if name == "title":
        return value if len(value) <= 120 and not any(p.match(value) for p in LABELS.values()) else None
    return None


def from_pdf_text(text: str) -> TitleBlock:
    lines = [re.sub(r"\s+", " ", line).strip() for line in text.splitlines()]
    lines = [line for line in lines if line]
    block = TitleBlock()
    for i, line in enumerate(lines):
        for name, label in LABELS.items():
            if getattr(block, name) is not None:
                continue
            match = label.match(line)
            if not match:
                continue
            value = _valid(name, match.group(1))
            if value is None and not match.group(1).strip() and i + 1 < len(lines):
                value = _valid(name, lines[i + 1])
            if value is not None:
                setattr(block, name, value)
            break
    return block


def number_from_file_name(stem: str) -> str | None:
    stem = stem.strip()
    return stem.upper() if FILE_NUMBER.match(stem) else None
