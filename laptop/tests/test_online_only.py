"""Dropbox's online-only files are listed by path and name and never opened; once local, they are read once."""

from pathlib import Path

import pytest

from vellum_indexer import files
from vellum_indexer.index import read_index

from conftest import FakeOnlineOnly
from makers import PLANT, SCHOOL, small_tree, touch


@pytest.mark.parametrize(
    "attributes, online_only",
    [
        (0, False),
        (0x20, False),  # FILE_ATTRIBUTE_ARCHIVE: an ordinary local file
        (0x80000, False),  # FILE_ATTRIBUTE_PINNED: always kept on this laptop
        (files.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS, True),
        (files.FILE_ATTRIBUTE_RECALL_ON_OPEN, True),
        (files.FILE_ATTRIBUTE_OFFLINE, True),
        (0x20 | 0x100000 | files.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS, True),  # unpinned, online-only
    ],
)
def test_which_attributes_mean_online_only(attributes, online_only):
    assert files.is_online_only(attributes) is online_only


def test_online_only_files_are_listed_but_never_opened(dropbox: Path, make_indexer):
    small_tree(dropbox)
    online = FakeOnlineOnly()
    online.names = {"V-12 Pump skid GA.pdf", "E-202.dwg", "M-101.pdf"}
    previews = []

    def preview(path):
        previews.append(path.name)
        return None

    indexer = make_indexer(attributes=online, read_preview=preview)
    indexer.scan()
    opened = indexer.read_pdf.names() + [p.name for p in indexer.dwg_reader.read_paths] + previews
    assert not set(opened) & online.names, opened
    assert indexer.counters.online_only_listed == 3

    _, entries = read_index(dropbox / "Vellum" / "Index")
    e = {x["name"]: x for x in entries}
    vendor = e["V-12 Pump skid GA.pdf"]
    assert vendor["path"] == f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf"
    assert vendor["pdf"]["read"] is False
    assert vendor["pdf"]["contentHash"] is None and vendor["thumbnail"] is None
    assert (vendor["title"], vendor["revision"], vendor["scale"], vendor["date"]) == (None, None, None, None)
    assert vendor["number"] is None and vendor["fieldsFrom"] is None

    unread_dwg = e["E-202.dwg"]
    assert unread_dwg["dwg"]["read"] is False
    assert unread_dwg["number"] == "E-202" and unread_dwg["fieldsFrom"] == "name"  # from its file name only

    # an online-only PDF still pairs by its name, which needs no reading
    m101 = e["M-101.dwg"]
    assert m101["pdf"]["path"] == f"/{SCHOOL}/Mechanical/M-101.pdf" and m101["pdf"]["read"] is False
    assert m101["revision"] == "C"  # from the DWG, which is local


def test_an_online_only_file_is_read_once_it_is_local(dropbox: Path, make_indexer):
    small_tree(dropbox)
    online = FakeOnlineOnly()
    online.names = {"V-12 Pump skid GA.pdf"}
    indexer = make_indexer(attributes=online)
    indexer.scan()
    assert "V-12 Pump skid GA.pdf" not in indexer.read_pdf.names()

    # a rescan while it is still online-only does not read it
    indexer.read_pdf.paths.clear()
    indexer.scan()
    assert indexer.read_pdf.names() == []

    online.names = set()  # Zach opened it, or made it available offline
    indexer.scan()
    assert indexer.read_pdf.names() == ["V-12 Pump skid GA.pdf"]
    _, entries = read_index(dropbox / "Vellum" / "Index")
    vendor = next(x for x in entries if x["name"] == "V-12 Pump skid GA.pdf")
    assert vendor["pdf"]["read"] is True and vendor["title"] == "Pump skid general arrangement"

    indexer.read_pdf.paths.clear()
    indexer.scan()
    assert indexer.read_pdf.names() == []


def test_a_watched_change_to_an_online_only_file_does_not_open_it(dropbox: Path, make_indexer):
    small_tree(dropbox)
    online = FakeOnlineOnly()
    indexer = make_indexer(attributes=online)
    indexer.scan()
    pdf = dropbox / PLANT / "PDF" / "E-201.pdf"
    online.names = {"E-201.pdf"}  # freed up to online-only on the laptop: Dropbox swaps in a placeholder
    touch(pdf, 1_800_000_000)
    indexer.read_pdf.paths.clear()
    indexer.update({f"/{PLANT}/PDF/E-201.pdf"})
    assert indexer.read_pdf.names() == []
