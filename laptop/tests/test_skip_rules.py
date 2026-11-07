from pathlib import Path

import pytest

from vellum_indexer import files
from vellum_indexer.files import SkipRules


@pytest.mark.parametrize(
    "path, indexed",
    [
        ("/Projects/Made-up Plant/E-201.dwg", True),
        ("/Projects/Made-up Plant/E-201.DWG", True),
        ("/Projects/Made-up Plant/PDF/E-201.pdf", True),
        ("/E-201.pdf", True),
        # Vellum's own folder, at the top only
        ("/Vellum/Index/index.json", False),
        ("/Vellum/Boiler walkdown 7f3a/sheets/x.pdf", False),
        ("/vellum/a.pdf", False),
        ("/Projects/Vellum notes/a.pdf", True),
        ("/Projects/Made-up Plant/Vellum/a.pdf", True),
        # Dropbox's caches, at any depth
        ("/.dropbox.cache/2026-11-01/E-201.pdf", False),
        ("/Projects/.dropbox.cache/E-201.dwg", False),
        ("/.dropbox/a.pdf", False),
        # temp, lock and backup files
        ("/Projects/Made-up Plant/~$E-201.dwg", False),
        ("/Projects/Made-up Plant/E-201.dwl", False),
        ("/Projects/Made-up Plant/E-201.dwl2", False),
        ("/Projects/Made-up Plant/E-201.bak", False),
        ("/Projects/Made-up Plant/E-201_1_1_1234.sv$", False),
        ("/Projects/Made-up Plant/.~E-201.pdf", False),
        # not a drawing
        ("/Projects/Made-up Plant/notes.txt", False),
        ("/Projects/Made-up Plant/E-201.dxf", False),
        ("/Projects/Made-up Plant/E-201.pdf.lnk", False),
    ],
)
def test_what_the_scan_keeps(path, indexed):
    assert SkipRules().indexes(path) is indexed


def test_settings_excludes_match_any_case_and_name_folders():
    rules = SkipRules(["/Personal/**", "**/Archive/**", "*/superseded*"])
    assert not rules.indexes("/Personal/taxes.pdf")
    assert not rules.indexes("/personal/deep/er/x.pdf")
    assert rules.skips_folder("/Personal")
    assert not rules.indexes("/Projects/Made-up Plant/Archive/E-201.pdf")
    assert not rules.indexes("/Projects/Made-up Plant/Superseded E-201.pdf")
    assert rules.indexes("/Personally made/E-201.pdf")
    assert rules.indexes("/Projects/Made-up Plant/E-201.pdf")


def test_walk_never_descends_into_skipped_folders(dropbox: Path):
    for rel in ["Vellum/Index/shards/a.pdf", ".dropbox.cache/b.pdf", "Projects/P/c.pdf", "Projects/P/~$d.dwg",
                "Projects/P/e.dwg", "Personal/f.pdf"]:
        p = dropbox / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")
    found = [f.path for f in files.walk(dropbox, SkipRules(["/Personal/**"]))]
    assert found == ["/Projects/P/c.pdf", "/Projects/P/e.dwg"]


def test_dropbox_paths_use_forward_slashes_from_the_root(dropbox: Path):
    p = dropbox / "Projects" / "Made-up Plant" / "E-201.dwg"
    assert files.dropbox_path(dropbox, p) == "/Projects/Made-up Plant/E-201.dwg"
    assert files.local_path(dropbox, "/Projects/Made-up Plant/E-201.dwg") == p
