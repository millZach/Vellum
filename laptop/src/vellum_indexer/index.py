"""The drawing index in Dropbox/Vellum/Index (format 1, docs/drawing-index-format.md, ADR-0017).

- ``index.json``, the manifest: the format, a generation, and one line per project's shard. It is small and is
  rewritten only when a shard changed, so one small read tells the Duo whether anything did.
- ``shards/<content hash>.json``: one project's drawings. A shard's name is the hash of its bytes, so the Duo
  downloads only the shards whose names it has not got, and an unchanged project is never written again.
- ``thumbnails/<content hash>.png``: one per drawing, named by its bytes, so an unchanged drawing never writes a
  new one and the Duo fetches only names it has not got.

Every file is written to a ``~$`` temp file beside it (Dropbox ignores those) and renamed over the old one, so
Dropbox never syncs half a file. Shards and thumbnails no longer referenced are deleted an hour later, so a Duo part
way through a refresh still finds what the manifest it read names.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath

from vellum_indexer.fields import Sheet, TitleBlock, number_from_file_name
from vellum_indexer.pairing import Candidate, pair
from vellum_indexer.pdf import THUMBNAIL_BOX
from vellum_indexer.projects import ProjectFinder
from vellum_indexer.state import Record

FORMAT = 1
MANIFEST = "index.json"
SHARDS = "shards"
THUMBNAILS = "thumbnails"
ORPHAN_GRACE_SECONDS = 3600


def content_name(data: bytes, suffix: str) -> str:
    return hashlib.sha256(data).hexdigest()[:32] + suffix


def iso(mtime_ns: int) -> str:
    return datetime.fromtimestamp(mtime_ns / 1e9, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def entry_id(primary_path: str, layout: str | None = None) -> str:
    key = primary_path.lower() + (f"#{layout.lower()}" if layout else "")
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]


def _file(record: Record) -> dict:
    out = {
        "path": record.path,
        "size": record.size,
        "modified": iso(record.mtime_ns),
        "read": record.reader != "unread",
    }
    if record.kind == "pdf":
        facts = record.facts
        out["contentHash"] = facts.get("contentHash")
        out["pages"] = facts.get("pages")
        out["paperInches"] = facts.get("paperInches")
    return out


def sheets_of(record: Record) -> list[Sheet]:
    """A DWG's title blocks, one per layout; a DWG with none read is one sheet with no layout and no fields."""
    sheets = [Sheet.from_dict(d) for d in record.facts.get("sheets") or []]
    return sheets or [Sheet("", TitleBlock())]


def build_entries(records: dict[str, Record], projects: ProjectFinder) -> list[dict]:
    """Every drawing: each DWG layout's title block (a sheet) with the PDF plotted from it if any, then each PDF
    with no DWG."""
    project_of = {k: projects.project_of(r.path) for k, r in records.items()}
    dwgs = [k for k, r in records.items() if r.kind == "dwg"]
    pdfs = [k for k, r in records.items() if r.kind == "pdf"]

    sheets: dict[str, tuple[str, Sheet]] = {}  # sheet key -> (DWG key, sheet)
    for k in dwgs:
        for sheet in sheets_of(records[k]):
            sheets[f"{k}#{sheet.layout.lower()}"] = (k, sheet)
    candidates_dwg = [
        Candidate(sk, records[k].path, project_of[k].path, number=sh.block.number, dwg=k, layout=sh.layout or None)
        for sk, (k, sh) in sheets.items()
    ]
    candidates_pdf = [
        Candidate(
            k, records[k].path, project_of[k].path,
            number=TitleBlock.from_dict(records[k].facts.get("text")).number,
            meta_title=records[k].facts.get("metaTitle"),
        )
        for k in pdfs
    ]
    pairs = pair(candidates_pdf, candidates_dwg)
    plots: dict[str, list[tuple[str, str]]] = {}
    for pdf_key, p in pairs.items():
        plots.setdefault(p.dwg_key, []).append((pdf_key, p.rule))

    entries = []
    for sheet_key, (dwg_key, sheet) in sheets.items():
        plotted = sorted(plots.get(sheet_key, []),
                         key=lambda kp: (-records[kp[0]].mtime_ns, records[kp[0]].path.lower()))
        pdf_key, rule = plotted[0] if plotted else (None, None)
        others = [records[k].path for k, _ in plotted[1:]]
        entries.append(_entry(records, project_of, dwg_key, sheet, pdf_key, rule, others))
    for pdf_key in pdfs:
        if pdf_key not in pairs:
            entries.append(_entry(records, project_of, None, None, pdf_key, None, []))
    entries.sort(key=lambda e: (e["path"].lower(), (e["layout"] or "").lower()))
    return entries


def _entry(records, project_of, dwg_key, sheet, pdf_key, rule, others) -> dict:
    dwg = records[dwg_key] if dwg_key else None
    pdf = records[pdf_key] if pdf_key else None
    primary = dwg or pdf
    project = project_of[dwg_key or pdf_key]
    from_dwg = sheet.block if sheet else TitleBlock()
    from_pdf = TitleBlock.from_dict(pdf.facts.get("text")) if pdf else TitleBlock()
    block = from_dwg.filled_from(from_pdf)
    source = "dwg" if from_dwg.any() else "pdf" if from_pdf.any() else None
    if block.number is None:
        block.number = number_from_file_name(PurePosixPath(primary.path).stem)
        if block.number and source is None:
            source = "name"
    layout = (sheet.layout or None) if sheet else None
    # A DWG's own preview stands in only when it has no PDF.
    thumbnail = (pdf.facts.get("thumbnail") if pdf else None) or (dwg.facts.get("thumbnail") if dwg else None)
    entry = {
        "id": entry_id(primary.path, layout),
        "path": primary.path,
        "name": PurePosixPath(primary.path).name,
        "layout": layout,
        "folder": str(PurePosixPath(primary.path).parent),
        "project": project.name,
        "projectPath": project.path,
        **block.as_dict(),
        "fieldsFrom": source,
        "dwg": _file(dwg) if dwg else None,
        "pdf": _file(pdf) if pdf else None,
        "otherPdfs": others,
        "pairedBy": rule,
        "thumbnail": thumbnail,
    }
    return entry


def shard_bytes(project: str | None, project_path: str | None, entries: list[dict]) -> bytes:
    shard = {"format": FORMAT, "project": project, "projectPath": project_path, "drawings": entries}
    return (json.dumps(shard, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def atomic_write(path: Path, data: bytes) -> None:
    """Write beside the target under a ``~$`` name Dropbox ignores, flush to disk, then rename over the target."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f"~${path.name}.{os.getpid()}.tmp")
    try:
        with open(temp, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        for attempt in range(10):
            try:
                os.replace(temp, path)
                return
            except PermissionError:  # Windows: Dropbox may have the old file open for a moment
                if attempt == 9:
                    raise
                time.sleep(0.2 * (attempt + 1))
    finally:
        temp.unlink(missing_ok=True)


@dataclass
class WriteCounts:
    files: int = 0
    bytes: int = 0
    deleted: int = 0
    names: list[str] = field(default_factory=list)


class IndexWriter:
    def __init__(self, folder: Path, now=lambda: datetime.now(UTC)):
        self.folder = folder
        self.now = now  # the manifest's "updated"; fixed when the fixture index is made
        self.counts = WriteCounts()

    def _write(self, rel: str, data: bytes) -> None:
        atomic_write(self.folder / rel, data)
        self.counts.files += 1
        self.counts.bytes += len(data)
        self.counts.names.append(rel)

    def publish(self, entries: list[dict], previous: dict | None, thumbnail_png) -> dict | None:
        """Write the thumbnails and shards that are not there yet and, if any shard changed, the manifest. Returns
        the manifest written, or None when nothing changed. ``thumbnail_png(name)`` gives a thumbnail's bytes from
        the state file. Thumbnails are written only once a published drawing names them, and any that went missing
        from Dropbox are written again."""
        for name in sorted({e["thumbnail"] for e in entries if e.get("thumbnail")}):
            if not (self.folder / THUMBNAILS / name).exists():
                png = thumbnail_png(name)
                if png is not None:
                    self._write(f"{THUMBNAILS}/{name}", png)
        groups: dict[str | None, list[dict]] = {}
        names: dict[str | None, str | None] = {}
        for e in entries:
            groups.setdefault(e["projectPath"], []).append(e)
            names[e["projectPath"]] = e["project"]
        shards = []
        for project_path in sorted(groups, key=lambda p: (p is not None, (p or "").lower())):
            data = shard_bytes(names[project_path], project_path, groups[project_path])
            name = content_name(data, ".json")
            if not (self.folder / SHARDS / name).exists():
                self._write(f"{SHARDS}/{name}", data)
            shards.append({
                "project": names[project_path],
                "projectPath": project_path,
                "file": f"{SHARDS}/{name}",
                "drawings": len(groups[project_path]),
                "bytes": len(data),
            })
        manifest_path = self.folder / MANIFEST
        if previous and previous.get("shards") == shards and manifest_path.exists():
            return None
        manifest = {
            "format": FORMAT,
            "generation": (previous or {}).get("generation", 0) + 1,
            "updated": self.now().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "drawings": len(entries),
            "thumbnailBox": THUMBNAIL_BOX,
            "shards": shards,
        }
        data = (json.dumps(manifest, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode("utf-8")
        self._write(MANIFEST, data)
        return manifest

    def collect(self, manifest: dict, entries: list[dict], orphans: dict[str, float], now: float) -> dict[str, float]:
        """Delete shards and thumbnails unreferenced for an hour; the orphans still waiting."""
        referenced = {s["file"] for s in manifest.get("shards", [])}
        referenced |= {f"{THUMBNAILS}/{e['thumbnail']}" for e in entries if e.get("thumbnail")}
        waiting = {}
        for sub in (SHARDS, THUMBNAILS):
            try:
                names = os.listdir(self.folder / sub)
            except OSError:
                continue
            for name in names:
                rel = f"{sub}/{name}"
                if rel in referenced or name.startswith("~$"):
                    continue
                since = orphans.get(rel, now)
                if now - since >= ORPHAN_GRACE_SECONDS:
                    try:
                        os.remove(self.folder / rel)
                        self.counts.deleted += 1
                    except OSError:
                        waiting[rel] = since
                else:
                    waiting[rel] = since
        return waiting


def read_index(folder: Path) -> tuple[dict, list[dict]]:
    """The manifest and every drawing in it, as the Duo would read them (tests and the fixture check)."""
    manifest = json.loads((folder / MANIFEST).read_text(encoding="utf-8"))
    if manifest.get("format") != FORMAT:
        raise ValueError(f"unknown index format {manifest.get('format')}")
    entries = []
    for shard in manifest["shards"]:
        data = (folder / shard["file"]).read_bytes()
        if content_name(data, ".json") != PurePosixPath(shard["file"]).name:
            raise ValueError(f"{shard['file']} does not match its name")
        entries.extend(json.loads(data)["drawings"])
    return manifest, entries
