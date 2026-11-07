from pathlib import Path

import pytest
from PIL import Image, ImageDraw

from vellum_indexer.dwg import read_preview
from vellum_indexer.index import content_name, read_index
from vellum_indexer.pdf import dropbox_content_hash, read_pdf

from makers import make_dwg_with_preview, make_pdf


def thumb(png: bytes) -> Image.Image:
    import io

    return Image.open(io.BytesIO(png))


def test_a_pdf_thumbnail_fits_the_duos_rows_at_2x(tmp_path: Path):
    landscape = read_pdf(make_pdf(tmp_path / "a.pdf", inches=(36, 24))).thumbnail_png
    portrait = read_pdf(make_pdf(tmp_path / "b.pdf", inches=(8.5, 11))).thumbnail_png
    assert thumb(landscape).size == (128, 86)  # 36 x 24, rendered at 256 x 171 and halved
    assert thumb(portrait).size == (99, 128)


def test_the_same_drawing_renders_to_the_same_bytes_and_so_the_same_name(tmp_path: Path):
    a = read_pdf(make_pdf(tmp_path / "a.pdf", [(100, 100, 40, "M-101")])).thumbnail_png
    b = read_pdf(make_pdf(tmp_path / "copy" / "a.pdf", [(100, 100, 40, "M-101")])).thumbnail_png
    c = read_pdf(make_pdf(tmp_path / "c.pdf", [(100, 100, 40, "M-101")], mark=5)).thumbnail_png
    assert content_name(a, ".png") == content_name(b, ".png")
    assert content_name(a, ".png") != content_name(c, ".png")


def test_one_thumbnail_file_serves_identical_drawings(dropbox: Path, make_indexer):
    for name in ("A-1", "A-2"):
        make_pdf(dropbox / "Projects" / "Made-up Job" / f"{name}.pdf", inches=(11, 8.5))
    make_indexer().scan()
    _, entries = read_index(dropbox / "Vellum" / "Index")
    assert len({e["thumbnail"] for e in entries}) == 1
    assert len(list((dropbox / "Vellum" / "Index" / "thumbnails").iterdir())) == 1


def made_up_preview() -> Image.Image:
    image = Image.new("RGB", (180, 120), "black")
    ImageDraw.Draw(image).rectangle((20, 20, 160, 100), outline="white", width=3)
    return image


@pytest.mark.parametrize("kind", ["png", "bmp"])
def test_a_dwgs_saved_preview_becomes_its_thumbnail(tmp_path: Path, kind):
    dwg = make_dwg_with_preview(tmp_path / "E-202.dwg", made_up_preview(), kind)
    png = read_preview(dwg)
    assert png is not None
    image = thumb(png)
    assert image.size == (128, 85)
    assert image.getpixel((64, 14)) != (0, 0, 0)  # the rectangle's top edge came through


def test_no_preview_means_no_thumbnail(tmp_path: Path):
    (tmp_path / "x.dwg").write_bytes(b"AC1032" + b"\0" * 200)
    (tmp_path / "y.dwg").write_bytes(b"not a dwg")
    assert read_preview(tmp_path / "x.dwg") is None
    assert read_preview(tmp_path / "y.dwg") is None


def test_a_dwg_with_no_pdf_shows_its_preview_and_one_with_a_pdf_shows_the_pdf(dropbox: Path, make_indexer):
    job = dropbox / "Projects" / "Made-up Job"
    make_dwg_with_preview(job / "E-1.dwg", made_up_preview())
    make_dwg_with_preview(job / "E-2.dwg", made_up_preview())
    make_pdf(job / "E-2.pdf", [(100, 100, 40, "E-2")], inches=(11, 8.5))
    make_indexer().scan()
    _, entries = read_index(dropbox / "Vellum" / "Index")
    e = {x["name"]: x for x in entries}
    preview_name = content_name(read_preview(job / "E-1.dwg"), ".png")
    assert e["E-1.dwg"]["thumbnail"] == preview_name
    assert e["E-2.dwg"]["thumbnail"] == content_name(read_pdf(job / "E-2.pdf").thumbnail_png, ".png")
    assert e["E-2.dwg"]["thumbnail"] != preview_name


def test_dropbox_content_hash(tmp_path: Path):
    import hashlib

    empty = tmp_path / "empty"
    empty.write_bytes(b"")
    assert dropbox_content_hash(empty) == hashlib.sha256(b"").hexdigest()
    two_blocks = tmp_path / "two"
    data = b"a" * (4 * 1024 * 1024) + b"b"
    two_blocks.write_bytes(data)
    expected = hashlib.sha256(
        hashlib.sha256(data[: 4 * 1024 * 1024]).digest() + hashlib.sha256(b"b").digest()).hexdigest()
    assert dropbox_content_hash(two_blocks) == expected


@pytest.mark.parametrize("rotate, paper", [(0, [36.0, 24.0]), (90, [24.0, 36.0]), (180, [36.0, 24.0]),
                                           (270, [24.0, 36.0])])
def test_a_rotated_page_reports_its_paper_as_it_is_viewed(tmp_path: Path, rotate, paper):
    facts = read_pdf(make_pdf(tmp_path / f"r{rotate}.pdf", inches=(36, 24), rotate=rotate))
    assert list(facts.paper_inches) == paper
