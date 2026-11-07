"""An unchanged file is not read again, a changed one is, a deleted one leaves the index; and the work counts are the
budgets in docs/perf/baselines/laptop-indexer.json."""

import json
import shutil
from pathlib import Path

from vellum_indexer.index import WriteCounts, read_index
from vellum_indexer.indexer import Counters

from makers import PLANT, SCHOOL, make_dxf, small_tree, title_block_pdf, touch

BASELINES = Path(__file__).resolve().parents[2] / "docs" / "perf" / "baselines" / "laptop-indexer.json"


def budget(metric: str) -> int:
    entries = json.loads(BASELINES.read_text())["entries"]
    return next(e for e in entries if e["metric"] == metric)["value"]


def rescan(indexer):
    indexer.counters = Counters()
    indexer.writer.counts = WriteCounts()
    indexer.read_pdf.paths.clear()
    indexer.dwg_reader.read_paths.clear()
    indexer.scan()
    return indexer.counters, indexer.writer.counts


def test_a_rescan_with_nothing_changed_reads_and_writes_nothing(dropbox: Path, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()
    indexer.scan()
    counters, writes = rescan(indexer)
    assert counters.files_read == budget("files_read_rescan_no_change") == 0
    assert writes.files == budget("index_files_written_rescan_no_change") == 0
    assert counters.thumbnails_made == budget("thumbnails_made_rescan_no_change") == 0
    assert indexer.read_pdf.paths == [] and indexer.dwg_reader.read_paths == []


def test_a_restart_reads_nothing_unchanged(dropbox: Path, make_indexer):
    small_tree(dropbox)
    first = make_indexer()
    first.scan()
    first.state.close()
    second = make_indexer()  # the same state file, as after a reboot
    second.scan()
    assert second.counters.files_read == 0
    assert second.writer.counts.files == 0


def test_one_changed_pdf_is_read_alone_and_writes_its_shard_its_thumbnail_and_the_manifest(dropbox, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()
    indexer.scan()
    pdf = dropbox / SCHOOL / "Mechanical" / "M-101.pdf"
    title_block_pdf(pdf, number="M-101", title="First floor HVAC plan", rev="D", scale='1/4" = 1\'-0"',
                    date="2026-11-07", mark=3)
    touch(pdf, 1_800_000_000)
    counters, writes = rescan(indexer)
    assert indexer.read_pdf.names() == ["M-101.pdf"]
    assert counters.files_read == budget("files_read_rescan_one_pdf_changed") == 1
    assert writes.files == budget("index_files_written_one_pdf_changed") == 3
    assert sorted(n.split("/")[0] for n in writes.names) == ["index.json", "shards", "thumbnails"]
    manifest, entries = read_index(dropbox / "Vellum" / "Index")
    assert manifest["generation"] == 2
    m101 = next(e for e in entries if e["name"] == "M-101.dwg")
    assert m101["revision"] == "C"  # the DWG's attributes still win over the PDF's text


def test_a_changed_dwg_is_read_again(dropbox: Path, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()
    indexer.scan()
    dwg = dropbox / PLANT / "CAD" / "E-202.dwg"
    make_dxf(dwg, [("Layout1", {"DWG_NO": "E-202", "TITLE": "Boiler room lighting plan", "REV": "1"})])
    touch(dwg, 1_800_000_000)
    rescan(indexer)
    assert [p.name for p in indexer.dwg_reader.read_paths] == ["E-202.dwg"]
    _, entries = read_index(dropbox / "Vellum" / "Index")
    assert next(e for e in entries if e["name"] == "E-202.dwg")["revision"] == "1"


def test_a_deleted_file_leaves_the_index(dropbox: Path, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()
    indexer.scan()
    (dropbox / PLANT / "PDF" / "E-201.pdf").unlink()
    (dropbox / PLANT / "Vendor" / "V-12 Pump skid GA.pdf").unlink()
    counters, _ = rescan(indexer)
    assert counters.removed == 2 and counters.files_read == 0
    _, entries = read_index(dropbox / "Vellum" / "Index")
    names = {e["name"] for e in entries}
    assert "V-12 Pump skid GA.pdf" not in names
    e201 = next(e for e in entries if e["name"] == "E-201.dwg")
    assert e201["pdf"] is None  # back to "no PDF yet"


def test_the_watchers_update_reads_only_the_paths_it_is_handed(dropbox: Path, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()
    indexer.scan()
    pdf = dropbox / PLANT / "PDF" / "E-201.pdf"
    title_block_pdf(pdf, number="E-201", title="Boiler room power plan", rev="B", mark=2, title_meta="E-201-Layout1")
    touch(pdf, 1_800_000_000)
    (dropbox / SCHOOL / "Mechanical" / "M-101.pdf").unlink()
    indexer.read_pdf.paths.clear()
    indexer.update({f"/{PLANT}/PDF/E-201.pdf", f"/{SCHOOL}/Mechanical/M-101.pdf", "/Vellum/Index/index.json"})
    assert indexer.read_pdf.names() == ["E-201.pdf"]
    _, entries = read_index(dropbox / "Vellum" / "Index")
    assert next(e for e in entries if e["name"] == "M-101.dwg")["pdf"] is None


def test_a_folder_moved_in_or_deleted_is_walked_or_dropped(dropbox: Path, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()
    indexer.scan()
    title_block_pdf(dropbox / "Projects" / "Made-up Dam" / "PDF" / "C-002.pdf", number="C-002")
    indexer.update(set(), {"/Projects/Made-up Dam"})
    shutil.rmtree(dropbox / SCHOOL)
    indexer.update(set(), {"/" + SCHOOL})
    _, entries = read_index(dropbox / "Vellum" / "Index")
    assert sorted(e["project"] for e in entries) == ["Made-up Dam", "Made-up Plant Upgrade", "Made-up Plant Upgrade",
                                                    "Made-up Plant Upgrade"]


def test_a_first_scan_stopped_part_way_carries_on(dropbox: Path, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()

    class Stop(BaseException):  # the process stopping, not a damaged PDF
        pass

    real = indexer.read_pdf.fn
    calls = []

    def stops_on_the_second(path):
        calls.append(path)
        if len(calls) == 2:
            raise Stop
        return real(path)

    indexer.read_pdf.fn = stops_on_the_second
    try:
        indexer.scan()
    except Stop:
        pass
    indexer.state.commit()  # what a clean shutdown keeps; a crash keeps the last batch
    indexer.state.close()
    again = make_indexer()
    again.scan()
    # Read in path order: E-201.dwg, E-202.dwg and E-201.pdf were kept before the stop on V-12; only the rest is read.
    assert again.read_pdf.names() == ["V-12 Pump skid GA.pdf", "M-101.pdf"]
    assert [p.name for p in again.dwg_reader.read_paths] == ["M-101.dwg"]
    assert len(read_index(dropbox / "Vellum" / "Index")[1]) == 4
