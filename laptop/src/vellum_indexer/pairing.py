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
``PDF/Mechanical``. Within a rule the longest matching stem wins, then the nearest DWG, then the first by path, so
the result never depends on the order files were found. Names compare without regard to case.

A DWG can have several PDFs (one per layout, or reissues). Its entry shows the most recently modified one; the
others are paired with it and so are not listed again as PDFs without a DWG.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from pathlib import PurePosixPath

SEPARATORS = (" - ", "-", "_", " ")
NEAR = 2


@dataclass
class Candidate:
    key: str
    path: str  # Dropbox path
    project: str | None  # the project folder's Dropbox path
    number: str | None = None  # from the title block (DWG attributes, or the PDF's text)
    meta_title: str | None = None  # PDFs only


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
    dwg_key: str
    rule: str  # "metadata" | "name" | "number"


def stems_named_by(name: str) -> list[str]:
    """Every DWG stem that ``name`` matches: itself, and each part of it that a separator follows."""
    found = {name}
    for i in range(1, len(name)):
        for sep in SEPARATORS:
            if name.startswith(sep, i) and len(name) > i + len(sep):
                found.add(name[:i])
    return sorted(found, key=len, reverse=True)


def pair(pdfs: list[Candidate], dwgs: list[Candidate]) -> dict[str, Pairing]:
    """PDF key -> the DWG it was plotted from, for the PDFs that have one."""
    by_stem: dict[tuple[str | None, str], list[Candidate]] = defaultdict(list)
    numbers: dict[tuple[str | None, str], list[Candidate]] = defaultdict(list)
    for dwg in dwgs:
        by_stem[(dwg.project, stem(dwg.path))].append(dwg)
        n = norm_number(dwg.number)
        if n:
            numbers[(dwg.project, n)].append(dwg)
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
            if len(matches) == 1:
                found = Pairing(matches[0].key, "number")
        if found is not None:
            result[pdf.key] = found
    return result


def _best(pdf: Candidate, name: str, by_stem: dict, rule: str) -> Pairing | None:
    """The longest stem first, then the nearest DWG, then the first by path."""
    for s in stems_named_by(name) if name else []:
        nearby = []
        for dwg in by_stem.get((pdf.project, s), []):
            d = distance(pdf, dwg)
            if d is not None:
                nearby.append((d, dwg.path.lower(), dwg))
        if nearby:
            return Pairing(min(nearby, key=lambda m: m[:2])[2].key, rule)
    return None
