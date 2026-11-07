import json
import os
from pathlib import Path

import pytest

from vellum_indexer import index as index_module
from vellum_indexer.index import FORMAT, IndexWriter, atomic_write, content_name, read_index

from makers import PLANT, SCHOOL, small_tree


def by_name(entries):
    return {e["name"]: e for e in entries}


def test_the_index_holds_every_drawing_with_its_pairs_and_markers(dropbox: Path, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()
    indexer.scan()
    manifest, entries = read_index(dropbox / "Vellum" / "Index")
    assert manifest["format"] == FORMAT == 1
    assert manifest["generation"] == 1
    assert manifest["drawings"] == len(entries) == 4
    assert [s["projectPath"] for s in manifest["shards"]] == ["/" + PLANT, "/" + SCHOOL]

    e = by_name(entries)
    paired = e["E-201.dwg"]
    assert paired["path"] == f"/{PLANT}/CAD/E-201.dwg"
    assert paired["folder"] == f"/{PLANT}/CAD"
    assert (paired["project"], paired["projectPath"]) == ("Made-up Plant Upgrade", "/" + PLANT)
    assert (paired["number"], paired["title"], paired["revision"], paired["scale"], paired["date"]) == (
        "E-201", "Boiler room power plan", "A", '1/4" = 1\'-0"', "2026-10-02")
    assert paired["fieldsFrom"] == "dwg"
    assert paired["pairedBy"] == "metadata"
    assert paired["dwg"]["path"] == f"/{PLANT}/CAD/E-201.dwg" and paired["dwg"]["read"] is True
    assert paired["pdf"]["path"] == f"/{PLANT}/PDF/E-201.pdf"
    assert paired["pdf"]["pages"] == 1 and paired["pdf"]["paperInches"] == [36.0, 24.0]
    assert len(paired["pdf"]["contentHash"]) == 64
    assert paired["thumbnail"].endswith(".png")

    no_pdf = e["E-202.dwg"]  # "No PDF yet" on the Duo
    assert no_pdf["pdf"] is None and no_pdf["dwg"] is not None and no_pdf["number"] == "E-202"
    assert no_pdf["thumbnail"] is None  # a DXF stand-in has no DWG preview

    vendor = e["V-12 Pump skid GA.pdf"]  # "PDF only, no DWG"
    assert vendor["dwg"] is None and vendor["pairedBy"] is None
    assert (vendor["number"], vendor["title"], vendor["revision"], vendor["scale"]) == (
        "V-12", "Pump skid general arrangement", "2", "1:20")
    assert vendor["fieldsFrom"] == "pdf"
    assert vendor["pdf"]["paperInches"] == [17.0, 11.0]

    assert e["M-101.dwg"]["pairedBy"] == "name"
    assert len({x["id"] for x in entries}) == 4


def test_shards_and_thumbnails_are_named_by_their_bytes(dropbox: Path, make_indexer):
    small_tree(dropbox)
    make_indexer().scan()
    folder = dropbox / "Vellum" / "Index"
    manifest = json.loads((folder / "index.json").read_text())
    for shard in manifest["shards"]:
        data = (folder / shard["file"]).read_bytes()
        assert shard["file"] == f"shards/{content_name(data, '.json')}"
        assert shard["bytes"] == len(data)
    thumbs = sorted((folder / "thumbnails").iterdir())
    assert len(thumbs) == 3
    for t in thumbs:
        assert t.name == content_name(t.read_bytes(), ".png")


def test_round_trip_a_republish_with_nothing_changed_writes_nothing(dropbox: Path, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()
    indexer.scan()
    folder = dropbox / "Vellum" / "Index"
    before = {p: p.read_bytes() for p in folder.rglob("*") if p.is_file()}
    indexer.writer.counts = index_module.WriteCounts()
    assert indexer.publish() is None
    assert indexer.writer.counts.files == 0
    assert {p: p.read_bytes() for p in folder.rglob("*") if p.is_file()} == before


def test_the_index_is_written_only_to_dropbox_vellum(dropbox: Path, make_indexer):
    small_tree(dropbox)
    before = {p: (p.stat().st_mtime_ns, p.read_bytes()) for p in dropbox.rglob("*") if p.is_file()}
    make_indexer().scan()
    after = {p: (p.stat().st_mtime_ns, p.read_bytes()) for p in dropbox.rglob("*") if p.is_file()}
    new = sorted(str(p.relative_to(dropbox)).replace(os.sep, "/") for p in set(after) - set(before))
    assert all(n.startswith("Vellum/Index/") for n in new), new
    assert {p: after[p] for p in before} == before  # nothing in a project folder changed


def test_atomic_write_never_leaves_half_a_file(tmp_path: Path, monkeypatch):
    target = tmp_path / "index.json"
    atomic_write(target, b"old")

    def fail(*_):
        raise OSError("disk pulled")

    monkeypatch.setattr(index_module.os, "replace", fail)
    with pytest.raises(OSError):
        atomic_write(target, b"new and longer")
    assert target.read_bytes() == b"old"
    assert [p.name for p in tmp_path.iterdir()] == ["index.json"]  # the temp file is gone too


def test_atomic_write_uses_a_temp_name_dropbox_ignores(tmp_path: Path, monkeypatch):
    seen = []
    real = os.replace

    def spy(src, dst):
        seen.append(Path(src).name)
        real(src, dst)

    monkeypatch.setattr(index_module.os, "replace", spy)
    atomic_write(tmp_path / "index.json", b"x")
    assert seen and seen[0].startswith("~$index.json.")


def test_unreferenced_shards_and_thumbnails_go_after_an_hour(tmp_path: Path):
    writer = IndexWriter(tmp_path)
    (tmp_path / "shards").mkdir()
    (tmp_path / "thumbnails").mkdir()
    for name in ("shards/keep.json", "shards/old.json", "thumbnails/keep.png", "thumbnails/old.png"):
        (tmp_path / name).write_bytes(b"x")
    manifest = {"shards": [{"file": "shards/keep.json"}]}
    entries = [{"thumbnail": "keep.png"}]
    waiting = writer.collect(manifest, entries, {}, now=1000.0)
    assert waiting == {"shards/old.json": 1000.0, "thumbnails/old.png": 1000.0}
    waiting = writer.collect(manifest, entries, waiting, now=1000.0 + 3599)
    assert len(waiting) == 2 and (tmp_path / "shards/old.json").exists()
    waiting = writer.collect(manifest, entries, waiting, now=1000.0 + 3600)
    assert waiting == {}
    assert sorted(str(p.relative_to(tmp_path)).replace(os.sep, "/") for p in tmp_path.rglob("*.*")) == [
        "shards/keep.json", "thumbnails/keep.png"]


def test_a_manifest_of_another_format_is_refused(tmp_path: Path):
    (tmp_path / "index.json").write_text(json.dumps({"format": 2, "shards": []}))
    with pytest.raises(ValueError):
        read_index(tmp_path)


def test_a_thumbnail_deleted_from_dropbox_is_written_again(dropbox: Path, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()
    indexer.scan()
    thumbs = sorted((dropbox / "Vellum" / "Index" / "thumbnails").iterdir())
    thumbs[0].unlink()
    indexer.publish()
    assert thumbs[0].exists()


def test_a_dwg_with_two_layouts_gives_two_drawings_each_with_its_own_scale_and_pdf(dropbox: Path, make_indexer):
    from makers import make_dxf, title_block_pdf, touch

    job = dropbox / "Projects" / "Made-up Pump House"
    make_dxf(job / "CAD" / "Power.dwg", [
        ("E-201", {"DWG_NO": "E-201", "TITLE": "Pump house power plan", "REV": "A", "SCALE": "1:20"}),
        ("E-202", {"DWG_NO": "E-202", "TITLE": "Pump house lighting plan", "REV": "B", "SCALE": "1:50"}),
    ])
    title_block_pdf(job / "PDF" / "Power-E-201.pdf", number="E-201", scale="1:20", title_meta="Power-E-201", mark=1)
    title_block_pdf(job / "PDF" / "Power-E-202.pdf", number="E-202", scale="1:50", title_meta="Power-E-202", mark=2)
    touch(job / "PDF" / "Power-E-201.pdf", 1_790_000_000)
    touch(job / "PDF" / "Power-E-202.pdf", 1_790_000_600)  # the newer plot
    make_indexer().scan()
    manifest, entries = read_index(dropbox / "Vellum" / "Index")
    assert manifest["drawings"] == 2
    e = {x["number"]: x for x in entries}
    assert set(e) == {"E-201", "E-202"}
    assert (e["E-201"]["layout"], e["E-201"]["title"], e["E-201"]["scale"], e["E-201"]["revision"]) == (
        "E-201", "Pump house power plan", "1:20", "A")
    assert (e["E-202"]["layout"], e["E-202"]["title"], e["E-202"]["scale"], e["E-202"]["revision"]) == (
        "E-202", "Pump house lighting plan", "1:50", "B")
    assert e["E-201"]["pdf"]["path"].endswith("/Power-E-201.pdf") and e["E-201"]["otherPdfs"] == []
    assert e["E-202"]["pdf"]["path"].endswith("/Power-E-202.pdf") and e["E-202"]["otherPdfs"] == []
    assert e["E-201"]["dwg"]["path"] == e["E-202"]["dwg"]["path"] == "/Projects/Made-up Pump House/CAD/Power.dwg"
    assert e["E-201"]["id"] != e["E-202"]["id"]
