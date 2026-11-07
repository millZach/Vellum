"""The project folder a drawing sits in.

1. Under a projects root (``/Projects`` unless settings.toml names others), the project is the root's top folder:
   ``/Projects/Plant Upgrade/Electrical/DWG/E-201.dwg`` is in ``/Projects/Plant Upgrade``.
2. Elsewhere it is the folder holding the drawing's discipline and format folders: walk up from the drawing's folder
   past folders named like ``DWG``, ``PDF``, ``Plots``, ``Electrical``, ``Issued`` or ``Rev C``, and the first folder
   that is none of those is the project. ``/Clients/Mill/Boiler 4/Mechanical/PDF/M-501.pdf`` is in
   ``/Clients/Mill/Boiler 4``.
3. A drawing at the top of Dropbox, or with only such folders above it, is in the top folder it sits in, or in no
   project when it sits in Dropbox's own top.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import PurePosixPath

GENERIC_FOLDERS = {
    "dwg", "dwgs", "cad", "autocad", "acad", "drawings", "drawing", "dwg files", "pdf", "pdfs", "plots", "plot",
    "plotted", "prints", "print", "sheets", "issued", "issue", "for construction", "ifc", "ifr", "ifa", "ifb",
    "as built", "as-built", "asbuilt", "as builts", "record", "archive", "archived", "old", "superseded", "xref",
    "xrefs", "working", "current", "backup", "mechanical", "electrical", "instrumentation", "controls", "control",
    "civil", "structural", "architectural", "arch", "piping", "plumbing", "process", "p&id", "p&ids", "pid", "pids",
    "hvac", "fire protection", "fire alarm", "lighting", "power", "telecom", "i&c", "e&i", "mech", "elec", "struct",
    "vendor", "vendors", "vendor drawings", "submittals", "general", "details", "schematics", "loops",
    "loop drawings", "one lines", "one-lines",
}
GENERIC_PATTERN = re.compile(
    r"^(?:rev(?:ision)?\.?\s*[a-z0-9]{1,3}|\d{4}-\d{2}-\d{2}|[mepicsa]|[a-z]-?\d{0,3}\s*(?:dwgs?|pdfs?)|"
    r"(?:issued|ifc|ifr|ifa)\b.*|\d{1,2}\s*-\s*(?:dwg|pdf|cad|drawings?)s?)$",
    re.I,
)


def is_generic(name: str) -> bool:
    lower = name.strip().lower()
    return lower in GENERIC_FOLDERS or bool(GENERIC_PATTERN.match(lower))


@dataclass(frozen=True)
class Project:
    name: str | None
    path: str | None  # the project folder's Dropbox path


NO_PROJECT = Project(None, None)


class ProjectFinder:
    def __init__(self, roots: list[str] | None = None):
        roots = ["/Projects"] if roots is None else roots
        self.roots = [("/" + r.strip("/")).lower() for r in roots if r.strip("/")]

    def project_of(self, db_path: str) -> Project:
        parts = [p for p in PurePosixPath(db_path).parent.parts if p != "/"]
        lowered = "/" + "/".join(p.lower() for p in parts)
        for root in self.roots:
            depth = root.count("/")
            if (lowered + "/").startswith(root + "/") and len(parts) > depth:
                return self._project(parts[: depth + 1])
        for end in range(len(parts), 0, -1):
            if not is_generic(parts[end - 1]):
                return self._project(parts[:end])
        return self._project(parts[:1]) if parts else NO_PROJECT

    @staticmethod
    def _project(parts: list[str]) -> Project:
        return Project(parts[-1], "/" + "/".join(parts))
