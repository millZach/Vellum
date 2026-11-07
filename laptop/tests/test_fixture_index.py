"""The made-up index in tests/fixtures/drawing-index, which the Duo's tests (#68) read, is format 1 and is what the
indexer writes today for scripts/make_fixture_index.py's made-up tree."""

import importlib.util
from pathlib import Path

from vellum_indexer.index import read_index

FIXTURE = Path(__file__).parent / "fixtures" / "drawing-index"
SCRIPT = Path(__file__).parents[1] / "scripts" / "make_fixture_index.py"


def strip_thumbnails(entries):
    # Thumbnail bytes come from PDFium's rendering, which could differ by a pixel between platforms; everything
    # else is exact.
    return [{k: v for k, v in e.items() if k != "thumbnail"} for e in entries]


def test_the_fixture_reads_as_format_1_with_every_marker_case():
    manifest, entries = read_index(FIXTURE)
    assert manifest["format"] == 1 and manifest["drawings"] == len(entries) == 8
    for e in entries:
        if e["thumbnail"]:
            assert (FIXTURE / "thumbnails" / e["thumbnail"]).is_file()
    no_pdf_yet = [e for e in entries if e["dwg"] and not e["pdf"]]
    pdf_only = [e for e in entries if e["pdf"] and not e["dwg"]]
    unread = [e for e in entries if e["pdf"] and not e["pdf"]["read"]]
    assert {e["number"] for e in no_pdf_yet} == {"E-201", "M-102"}
    assert {e["name"] for e in pdf_only} == {"V-12 Pump skid GA.pdf", "Made-up loose sketch.pdf"}
    assert [e["number"] for e in unread] == ["I-302"]
    assert {e["scale"] for e in entries} >= {"AS NOTED", "NTS", '1/4" = 1\'-0"', "1:20"}
    assert next(e for e in entries if e["number"] == "M-501")["pdf"]["pages"] == 3
    assert next(e for e in entries if e["number"] == "I-301")["otherPdfs"] == [
        "/Projects/Made-up Plant Upgrade/Instrumentation/PDF/I-301 - Rev 0 issued.pdf"]
    assert next(e for e in entries if e["name"] == "Made-up loose sketch.pdf")["project"] is None


def test_the_fixture_is_what_the_indexer_writes_now(tmp_path: Path):
    spec = importlib.util.spec_from_file_location("make_fixture_index", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    fresh = module.make(tmp_path / "index")
    want_manifest, want = read_index(FIXTURE)
    got_manifest, got = read_index(fresh)
    assert strip_thumbnails(got) == strip_thumbnails(want), "run scripts/make_fixture_index.py and commit the result"
    assert got_manifest["drawings"] == want_manifest["drawings"]
