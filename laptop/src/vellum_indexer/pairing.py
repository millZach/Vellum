"""Pairing each PDF with the DWG it was plotted from.

A PDF is paired with at most one DWG, by the first of these rules that finds one:

1. **Plot metadata.** The PDF's Title, which AutoCAD's plot sets to the drawing's name and often its layout
   (``M-101``, ``M-101-Layout1``, ``M-101.dwg - Sheet 1``), names a nearby DWG: the title, less any ``.dwg``, is the
   DWG's name stem, or the stem followed by a separator (`` - ``, ``-``, ``_``, space) and more.
2. **Same name.** The PDF's name stem is a nearby DWG's stem, or the stem followed by a separator and more
   (``M-101 - Layout1.pdf``, ``M-101_Rev C.pdf``).
3. **Same drawing number.** The drawing number read from the PDF's title block text is the number read from exactly
   one DWG's title block attributes in the same project, comparing letters and digits only (``E 201`` is ``E-201``).

"Nearby" means the PDF's and the DWG's folders meet at most two folders up from each, inside the same project
folder: the same folder, a ``PDF`` or ``Plots`` folder beside or under the DWG's, or ``CAD/Mechanical`` beside
``PDF/Mechanical``. Names compare without regard to case.

A wrong pair is worse than none, because a redline would go to the wrong DWG:

- A name or title match whose title block numbers contradict (the PDF's text says ``E-201-1``, every one of the DWG's
  title blocks says otherwise) is not a match.
- Within a rule the longest matching stem wins, then the nearest DWG. Two DWGs equally near are told apart by the
  PDF's drawing number; when it can't tell them apart, the PDF is left unpaired ("PDF only, no DWG").

A DWG with several layouts has a title block (a sheet) per layout, and a PDF pairs with one sheet: the layout its
title or name names after the DWG's name (AutoCAD's ``Power-E-202``), else the sheet with its drawing number, else the
DWG's first sheet. A sheet with several PDFs (reissues) shows the most recently modified one; the others are paired
with it and so are not listed again as PDFs without a DWG.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from pathlib import PurePosixPath

SEPARATORS = (" - ", "-", "_", " ")
NEAR = 2


@dataclass
class Candidate:
    key: str  # a PDF's key, or a DWG sheet's key
    path: str  # Dropbox path
    project: str | None  # the project folder's Dropbox path
    number: str | None = None  # from the title block (a DWG sheet's attributes, or the PDF's text)
    meta_title: str | None = None  # PDFs only
    dwg: str | None = None  # a sheet's DWG key; a DWG's sheets share it
    layout: str | None = None  # a sheet's layout name


def stem(path: str) -> str:
    return PurePosixPath(path).stem.lower().strip()


def folder_parts(path: str) -> list[str]:
    return [p.lower() for p in PurePosixPath(path).parent.parts if p != "/"]


def distance(pdf: Candidate, dwg: Candidate) -> int | None:
    """Folders up plus folders down from the PDF's folder to the DWG's, or None when they are not nearby."""
    if pdf.project != dwg.project:
        return None
    a, b = folder_parts(pdf.path), folder_parts(dwg.path)
    common = 0
    while common < min(len(a), len(b)) and a[common] == b[common]:
        common += 1
    up, down = len(a) - common, len(b) - common
    if up > NEAR or down > NEAR:
        return None
    if pdf.project is not None and common < len(folder_parts(pdf.project + "/x")):
        return None  # they meet above the project folder
    return up + down


def title_name(title: str) -> str:
    return title.lower().replace(".dwg", "").strip()


def norm_number(number: str | None) -> str | None:
    if not number:
        return None
    # E-201, E 201 and E201 are one number; only letters and digits count.
    return "".join(ch for ch in number.upper() if ch.isalnum()) or None


@dataclass
class Pairing:
    dwg_key: str  # the sheet's key
    rule: str  # "metadata" | "name" | "number"


AMBIGUOUS = Pairing("", "ambiguous")


def stems_named_by(name: str) -> list[str]:
    """Every DWG stem that ``name`` matches: itself, and each part of it that a separator follows."""
    found = {name}
    for i in range(1, len(name)):
        for sep in SEPARATORS:
            if name.startswith(sep, i) and len(name) > i + len(sep):
                found.add(name[:i])
    return sorted(found, key=len, reverse=True)


def contradicts(pdf: Candidate, sheet: Candidate) -> bool:
    a, b = norm_number(pdf.number), norm_number(sheet.number)
    return a is not None and b is not None and a != b


def pair(pdfs: list[Candidate], sheets: list[Candidate]) -> dict[str, Pairing]:
    """PDF key -> the DWG sheet it was plotted from, for the PDFs that have one. ``sheets`` are the DWGs' title
    blocks, one per layout (a DWG with none read is one sheet with no number)."""
    by_stem: dict[tuple[str | None, str], dict[str, list[Candidate]]] = defaultdict(lambda: defaultdict(list))
    numbers: dict[tuple[str | None, str], list[Candidate]] = defaultdict(list)
    for sheet in sheets:
        by_stem[(sheet.project, stem(sheet.path))][sheet.dwg or sheet.key].append(sheet)
        n = norm_number(sheet.number)
        if n:
            numbers[(sheet.project, n)].append(sheet)
    result: dict[str, Pairing] = {}
    for pdf in pdfs:
        found = None
        if pdf.meta_title:
            found = _best(pdf, title_name(pdf.meta_title), by_stem, "metadata")
        if found is None:
            found = _best(pdf, stem(pdf.path), by_stem, "name")
        if found is None:
            n = norm_number(pdf.number)
            matches = numbers.get((pdf.project, n), []) if n else []
            if len({m.dwg or m.key for m in matches}) == 1:
                found = Pairing(matches[0].key, "number")
        if found is not None and found is not AMBIGUOUS:
            result[pdf.key] = found
    return result


def _best(pdf: Candidate, name: str, by_stem: dict, rule: str) -> Pairing | None:
    """The longest stem first, then the nearest DWG. A DWG whose every sheet's number contradicts the PDF's is no
    match. When two DWGs are equally near, the PDF's number decides; if it can't, the PDF stays unpaired (AMBIGUOUS):
    a wrong pair would send a redline to the wrong DWG."""
    for s in stems_named_by(name) if name else []:
        nearby: list[tuple[int, list[Candidate]]] = []
        for dwg_sheets in by_stem.get((pdf.project, s), {}).values():
            kept = [sh for sh in dwg_sheets if not contradicts(pdf, sh)]
            if not kept:
                continue
            d = distance(pdf, kept[0])
            if d is not None:
                nearby.append((d, kept))
        if not nearby:
            continue
        nearest = min(d for d, _ in nearby)
        tied = [kept for d, kept in nearby if d == nearest]
        if len(tied) > 1:
            n = norm_number(pdf.number)
            tied = [kept for kept in tied if n and any(norm_number(sh.number) == n for sh in kept)]
            if len(tied) != 1:
                return AMBIGUOUS
        return Pairing(_sheet_for(pdf, name, s, tied[0]).key, rule)
    return None


def _sheet_for(pdf: Candidate, name: str, dwg_stem: str, sheets: list[Candidate]) -> Candidate:
    """Which of a DWG's sheets the PDF was plotted from: the layout its name or title names after the DWG's name
    (``Power-E-202`` is layout ``E-202``), else the sheet with its number, else the first."""
    if len(sheets) == 1:
        return sheets[0]
    rest = name[len(dwg_stem):]
    for sep in SEPARATORS:
        if rest.startswith(sep):
            rest = rest[len(sep):]
            break
    rest = rest.strip()
    for sheet in sheets:
        if sheet.layout and sheet.layout.lower().strip() == rest:
            return sheet
    n = norm_number(pdf.number)
    for sheet in sheets:
        if n and norm_number(sheet.number) == n:
            return sheet
    for sheet in sheets:
        if norm_number(sheet.number) and norm_number(sheet.number) == norm_number(rest):
            return sheet
    return sheets[0]
