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
    # PDFs first, in path order: E-201.pdf was kept before the stop on V-12; only the rest is read.
    assert again.read_pdf.names() == ["V-12 Pump skid GA.pdf", "M-101.pdf"]
    assert [p.name for p in again.dwg_reader.read_paths] == ["E-201.dwg", "E-202.dwg", "M-101.dwg"]
    assert len(read_index(dropbox / "Vellum" / "Index")[1]) == 4


def test_a_long_scan_reads_pdfs_first_and_takes_watched_changes_between_files(dropbox: Path, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()
    order = []
    real_pdf, real_dwg = indexer.read_pdf.fn, indexer.dwg_reader.read
    indexer.read_pdf.fn = lambda p: order.append(p.name) or real_pdf(p)
    indexer.dwg_reader.read = lambda p: order.append(p.name) or real_dwg(p)
    saved = f"/{PLANT}/CAD/E-202.dwg"
    batches = [None, None, ({saved}, set())]  # the watcher has a saved DWG ready after the second file

    def poll():
        return batches.pop(0) if batches else None

    indexer.poll_changes = poll
    indexer.scan()
    assert order[:3] == ["E-201.pdf", "V-12 Pump skid GA.pdf", "E-202.dwg"]  # the batch's DWG jumps the queue
    assert order.count("E-202.dwg") == 1  # and is not read again when the scan reaches it
    assert sorted(order) == sorted(["E-201.pdf", "V-12 Pump skid GA.pdf", "M-101.pdf", "E-201.dwg", "E-202.dwg",
                                    "M-101.dwg"])


def test_a_folder_that_cannot_be_listed_keeps_its_drawings(dropbox: Path, make_indexer, monkeypatch):
    small_tree(dropbox)
    indexer = make_indexer()
    indexer.scan()
    import os as os_module

    from vellum_indexer import files as files_module

    real = os_module.scandir
    school = dropbox / SCHOOL / "Mechanical"

    def flaky(path):
        if Path(path) == school:
            raise PermissionError("made-up sharing violation")
        return real(path)

    monkeypatch.setattr(files_module.os, "scandir", flaky)
    counters, _ = rescan(indexer)
    assert counters.removed == 0
    assert len(read_index(dropbox / "Vellum" / "Index")[1]) == 4


def test_losing_the_state_file_carries_on_from_the_index_in_dropbox(dropbox: Path, make_indexer, tmp_path):
    small_tree(dropbox)
    first = make_indexer()
    first.scan()
    first.state.close()
    (tmp_path / "home" / "state.sqlite").unlink()  # uninstall -Purge, or a new laptop
    for leftover in (tmp_path / "home").glob("state.sqlite-*"):
        leftover.unlink()
    again = make_indexer()
    again.scan()
    assert again.counters.files_read == 6  # nothing is known, so everything is read again
    assert again.writer.counts.files == 0  # but nothing unchanged is written: same shards, same thumbnails
    assert read_index(dropbox / "Vellum" / "Index")[0]["generation"] == 1
    pdf = dropbox / SCHOOL / "Mechanical" / "M-101.pdf"
    title_block_pdf(pdf, number="M-101", rev="D", mark=7)
    touch(pdf, 1_800_000_000)
    again.scan()
    assert read_index(dropbox / "Vellum" / "Index")[0]["generation"] == 2  # never back to 1


def test_a_folder_copy_reported_as_folder_and_file_events_reads_each_file_once(dropbox: Path, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()
    indexer.scan()
    indexer.dwg_reader.read_paths.clear()
    make_dxf(dropbox / "Projects" / "Made-up Dam" / "CAD" / "C-002.dwg", [("Layout1", {"DWG_NO": "C-002"})])
    # Windows reports a copied-in folder as the folder, then the file made and the file modified
    indexer.update({"/Projects/Made-up Dam/CAD/C-002.dwg"},
                   {"/Projects/Made-up Dam", "/Projects/Made-up Dam/CAD"})
    assert [p.name for p in indexer.dwg_reader.read_paths] == ["C-002.dwg"]


def test_a_save_during_a_large_watched_batch_is_indexed_before_the_batch_ends(dropbox: Path, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()
    indexer.scan()
    big = dropbox / "Projects" / "Made-up Dam" / "CAD"
    for i in range(30):
        make_dxf(big / f"C-{i:03}.dwg", [("Layout1", {"DWG_NO": f"C-{i:03}"})])
    saved = dropbox / PLANT / "PDF" / "E-201.pdf"
    indexer.dwg_reader.read_paths.clear()
    seen_at = {}
    real = indexer.dwg_reader.read

    def read(path):
        n = len(indexer.dwg_reader.read_paths) + 1
        if n == 10:  # the save has been in the index since the 6th file, mid-batch
            e201 = next(e for e in read_index(dropbox / "Vellum" / "Index")[1] if e["name"] == "E-201.dwg")
            seen_at[n] = e201["pdf"]["modified"]
        return real(path)

    indexer.dwg_reader.read = read
    polls = []

    def poll():
        polls.append(len(indexer.dwg_reader.read_paths))
        if len(indexer.dwg_reader.read_paths) == 5 and not seen_at.get("saved"):
            seen_at["saved"] = True
            title_block_pdf(saved, number="E-201", rev="B", mark=9, title_meta="E-201-Layout1")
            touch(saved, 1_800_000_000)
            return ({f"/{PLANT}/PDF/E-201.pdf"}, set())
        return None

    indexer.poll_changes = poll
    indexer.update(set(), {"/Projects/Made-up Dam"})
    assert len(indexer.dwg_reader.read_paths) == 30
    assert seen_at[10] == "2027-01-15T08:00:00Z"  # 1_800_000_000 seconds


def test_a_watched_file_whose_folder_cannot_be_listed_keeps_its_drawing(dropbox: Path, make_indexer, monkeypatch):
    small_tree(dropbox)
    indexer = make_indexer()
    indexer.scan()
    from vellum_indexer import files as files_module

    real = files_module.os.scandir
    school = dropbox / SCHOOL / "Mechanical"

    def flaky(path):
        if Path(path) == school:
            raise PermissionError("made-up sharing violation")
        return real(path)

    monkeypatch.setattr(files_module.os, "scandir", flaky)
    indexer.update({f"/{SCHOOL}/Mechanical/M-101.pdf"}, {f"/{SCHOOL}/Mechanical"})
    assert indexer.counters.removed == 0
    names = {e["name"] for e in read_index(dropbox / "Vellum" / "Index")[1]}
    assert "M-101.dwg" in names and len(names) == 4
    m101 = next(e for e in read_index(dropbox / "Vellum" / "Index")[1] if e["name"] == "M-101.dwg")
    assert m101["pdf"] is not None
