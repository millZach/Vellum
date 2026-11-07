"""The laptop indexer's timings on a made-up Dropbox (docs/perf/baselines/laptop-indexer.json).

usage: python scripts/bench.py [--files 5000] [--out measurements.json]

Builds a made-up tree of N files across 50 projects (40% DWGs, 40% PDFs, 20% lock, backup and other files the scan
skips), then times a first scan, a rescan with nothing changed, a rescan with one PDF changed, and the update the
watcher makes for one saved PDF. DWGs are read by a stand-in reader (CI has no AutoCAD), so the first scan's time is
the PDF reading, thumbnails, listing and publishing, not AutoCAD's. Writes {"measurements": [...]} for
apps/ios/Scripts/perf-compare.py, and prints the counts beside the times.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE.parent / "src"), str(HERE.parent / "tests")]

from PIL import Image, ImageDraw  # noqa: E402

from vellum_indexer.dwg import BlockInsert  # noqa: E402
from vellum_indexer.index import WriteCounts  # noqa: E402
from vellum_indexer.indexer import Counters, Indexer  # noqa: E402
from vellum_indexer.state import State  # noqa: E402

from makers import make_dwg_with_preview, title_block_pdf, touch  # noqa: E402


class StandInReader:
    id = "bench-1"

    def read(self, path: Path) -> list[BlockInsert]:
        return [BlockInsert("Layout1", "TB", {"DWG_NO": path.stem, "TITLE": f"Made-up drawing {path.stem}",
                                              "REV": "A", "SCALE": '1/4" = 1\'-0"', "DATE": "2026-11-07"})]


def build(root: Path, total: int) -> Path:
    preview = Image.new("RGB", (160, 107), "black")
    ImageDraw.Draw(preview).rectangle((10, 10, 150, 97), outline="white", width=2)
    per_project = total // 50
    dwgs = pdfs = per_project * 2 // 5
    others = per_project - dwgs - pdfs
    changed = None
    t = 1_790_000_000
    for p in range(50):
        project = root / "Projects" / f"Made-up Project {p:02}"
        for i in range(dwgs):
            number = f"M-{p:02}{i:03}"
            make_dwg_with_preview(project / "CAD" / f"{number}.dwg", preview)
        for i in range(pdfs):
            number = f"M-{p:02}{i:03}" if i < pdfs * 3 // 4 else f"V-{p:02}{i:03}"
            path = title_block_pdf(project / "PDF" / f"{number}.pdf", number=number, title=f"Made-up drawing {number}",
                                   rev="A", scale='1/4" = 1\'-0"', date="2026-11-07", inches=(36, 24), mark=i % 9)
            changed = changed or path
        for i in range(others):
            name = ("~$M-{0}.dwg", "M-{0}.dwl", "M-{0}.bak", "notes-{0}.txt")[i % 4].format(i)
            (project / "CAD" / name).write_bytes(b"made up")
    for i, f in enumerate(sorted(q for q in root.rglob("*") if q.is_file())):
        touch(f, t + i)
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--files", type=int, default=5000)
    parser.add_argument("--out", type=Path, default=Path("laptop-indexer-measurements.json"))
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        root = tmp / "Dropbox"
        started = time.perf_counter()
        changed = build(root, args.files)
        files_made = sum(1 for q in root.rglob("*") if q.is_file())
        print(f"Made {files_made} made-up files in {time.perf_counter() - started:.1f} s")
        state = State(tmp / "home" / "state.sqlite")
        indexer = Indexer(root, state, dwg_reader=StandInReader(), progress_seconds=3600)
        results = {}

        def timed(name, fn):
            indexer.counters = Counters()
            indexer.writer.counts = WriteCounts()
            t0 = time.perf_counter()
            fn()
            results[name] = time.perf_counter() - t0
            c, w = indexer.counters, indexer.writer.counts
            print(f"{name}: {results[name]:.3f} s, listed {c.stat_files}, read {c.files_read}, "
                  f"thumbnails made {c.thumbnails_made}, index files written {w.files} ({w.bytes} bytes)")
            return c, w

        timed("first_scan_s", indexer.scan)
        c, w = timed("rescan_no_change_s", indexer.scan)
        assert c.files_read == 0 and w.files == 0, "a rescan with nothing changed read or wrote something"

        def change_one():
            title_block_pdf(changed, number=changed.stem, title=f"Made-up drawing {changed.stem}", rev="B",
                            inches=(36, 24), mark=11)
            touch(changed, 1_800_000_000)

        change_one()
        c, w = timed("rescan_one_pdf_changed_s", indexer.scan)
        assert c.files_read == 1, f"read {c.files_read} files after one changed"

        title_block_pdf(changed, number=changed.stem, rev="C", inches=(36, 24), mark=12)
        touch(changed, 1_800_000_100)
        db = "/" + changed.relative_to(root).as_posix()
        c, w = timed("update_one_pdf_saved_s", lambda: indexer.update({db}))
        assert c.files_read == 1
        manifest = json.loads((root / "Vellum" / "Index" / "index.json").read_text())
        print(f"Index: {manifest['drawings']} drawings in {len(manifest['shards'])} shards, manifest "
              f"{(root / 'Vellum' / 'Index' / 'index.json').stat().st_size} bytes")
        state.close()
    measurements = {"measurements": [{"metric": k, "value": round(v, 3)} for k, v in results.items()]}
    args.out.write_text(json.dumps(measurements, indent=1) + "\n")
    print(f"Wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
