"""Reading a local PDF once: its Dropbox content hash, metadata, page count, paper size, first page's text and a
thumbnail. PDFium (pypdfium2) does the reading and rendering; Pillow writes the PNG."""

from __future__ import annotations

import hashlib
import io
from dataclasses import dataclass
from pathlib import Path

import pypdfium2 as pdfium
from PIL import Image

# The Duo's search rows (variant B) show a thumbnail 56 x 38 points unfolded and 62 x 42 folded: 124 x 84 pixels at
# 2x. A thumbnail fits in 128 x 128 keeping the page's shape, so a landscape sheet is 128 x 85.
THUMBNAIL_BOX = 128

DROPBOX_BLOCK = 4 * 1024 * 1024


def dropbox_content_hash(path: Path) -> str:
    """Dropbox's content hash: SHA-256 of the concatenated SHA-256s of each 4 MiB block. The Duo names its cached
    PDFs by it (ADR-0010), so the index can say which drawings are already on the Duo."""
    blocks = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            block = f.read(DROPBOX_BLOCK)
            if not block:
                break
            blocks.update(hashlib.sha256(block).digest())
    return blocks.hexdigest()


@dataclass
class PdfFacts:
    content_hash: str
    pages: int
    paper_inches: tuple[float, float] | None
    meta_title: str | None
    meta_creator: str | None
    meta_producer: str | None
    text: str
    thumbnail_png: bytes | None


def png_bytes(image: Image.Image) -> bytes:
    """A deterministic PNG: the same picture always gives the same bytes, so its content name is stable."""
    out = io.BytesIO()
    image.save(out, format="PNG", optimize=True)
    return out.getvalue()


def fit(image: Image.Image, box: int = THUMBNAIL_BOX) -> Image.Image:
    image = image.convert("RGB")
    image.thumbnail((box, box), Image.Resampling.LANCZOS)
    return image


def read_pdf(path: Path) -> PdfFacts:
    content_hash = dropbox_content_hash(path)
    doc = pdfium.PdfDocument(str(path))
    try:
        meta = doc.get_metadata_dict(skip_empty=True)
        pages = len(doc)
        paper = None
        text = ""
        thumbnail = None
        if pages:
            page = doc[0]
            try:
                width, height = page.get_size()
                rotation = page.get_rotation()
                if rotation in (90, 270):
                    width, height = height, width
                paper = (round(width / 72, 3), round(height / 72, 3))
                textpage = page.get_textpage()
                try:
                    text = textpage.get_text_bounded() or ""
                finally:
                    textpage.close()
                long_edge = max(width, height) or 1
                scale = THUMBNAIL_BOX * 2 / long_edge  # render at twice the size, then downsample for smooth lines
                bitmap = page.render(scale=scale, fill_color=(255, 255, 255, 255))
                try:
                    thumbnail = png_bytes(fit(bitmap.to_pil()))
                finally:
                    bitmap.close()
            finally:
                page.close()
    finally:
        doc.close()
    return PdfFacts(
        content_hash=content_hash,
        pages=pages,
        paper_inches=paper,
        meta_title=meta.get("Title"),
        meta_creator=meta.get("Creator"),
        meta_producer=meta.get("Producer"),
        text=text,
        thumbnail_png=thumbnail,
    )
