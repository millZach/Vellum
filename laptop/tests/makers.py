"""Made-up drawings for the tests: PDFs written by hand, DXF title blocks made with ezdxf standing in for DWGs, and
DWG headers carrying a preview. Nothing here comes from a real drawing."""

from __future__ import annotations

import io
import os
import struct
from pathlib import Path

import ezdxf
from PIL import Image

from vellum_indexer.dwg import PREVIEW_SENTINEL, BlockInsert


def _escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def make_pdf(
    path: Path,
    lines: list[tuple[float, float, float, str]] | None = None,
    *,
    title: str | None = None,
    creator: str | None = None,
    inches: tuple[float, float] = (36, 24),
    pages: int = 1,
    mark: int = 0,
    rotate: int = 0,
) -> Path:
    """A PDF with text at (x, y) in points and a border; ``mark`` changes the drawing so the picture changes."""
    w, h = inches[0] * 72, inches[1] * 72
    text = "".join(f"BT /F1 {size} Tf {x} {y} Td ({_escape(t)}) Tj ET\n" for x, y, size, t in (lines or []))
    art = f"0 0 0 RG 6 w 36 36 {w - 72} {h - 72} re S\n{72 + mark * 40} 144 m {w / 2} {h / 2} l S\n"
    content = (art + text).encode("latin-1")
    objects: list[bytes] = []
    kids = " ".join(f"{4 + 2 * i} 0 R" for i in range(pages))
    objects.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    objects.append(f"<< /Type /Pages /Kids [{kids}] /Count {pages} >>".encode())
    objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for i in range(pages):
        page_no = 4 + 2 * i
        objects.append(
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {w} {h}] /Rotate {rotate} "
            f"/Resources << /Font << /F1 3 0 R >> >> "
            f"/Contents {page_no + 1} 0 R >>".encode()
        )
        objects.append(b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream")
    info = []
    if title is not None:
        info.append(f"/Title ({_escape(title)})")
    if creator is not None:
        info.append(f"/Creator ({_escape(creator)})")
    objects.append(f"<< {' '.join(info)} >>".encode())
    info_no = len(objects)
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n")
    offsets = []
    for n, body in enumerate(objects, 1):
        offsets.append(out.tell())
        out.write(f"{n} 0 obj\n".encode() + body + b"\nendobj\n")
    xref = out.tell()
    out.write(f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode())
    for off in offsets:
        out.write(f"{off:010d} 00000 n \n".encode())
    out.write(f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R /Info {info_no} 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(out.getvalue())
    return path


def title_block_pdf(path: Path, number=None, title=None, rev=None, scale=None, date=None, title_meta=None,
                    **kw) -> Path:
    """A made-up title block in the lower right, label above value, the way a title block prints."""
    x = kw.get("inches", (36, 24))[0] * 72 - 400
    lines = [(x, 300, 10, "MADE-UP ENGINEERING CO.")]
    y = 260
    for label, value in (("DRAWING TITLE", title), ("DWG NO.", number), ("REV", rev), ("SCALE", scale),
                         ("DATE", date)):
        if value is not None:
            lines.append((x, y, 7, label))
            lines.append((x, y - 12, 12, value))
            y -= 40
    kw.setdefault("creator", "Made-up CAD 2026" if title_meta else None)
    return make_pdf(path, lines, title=title_meta, **kw)


def make_dxf(path: Path, inserts: list[tuple[str, dict[str, str]]]) -> Path:
    """A DXF standing in for a DWG: per (layout, {tag: value}), a block insert with those attributes."""
    doc = ezdxf.new("R2018")
    for n, (layout_name, attributes) in enumerate(inserts):
        block = doc.blocks.new(name=f"TB{n}")
        block.add_lwpolyline([(0, 0), (10, 0), (10, 3), (0, 3)], close=True)
        for i, tag in enumerate(attributes):
            block.add_attdef(tag, insert=(0.2, 0.2 + i * 0.3), dxfattribs={"height": 0.1})
        layout = doc.modelspace() if layout_name == "Model" else (
            doc.layouts.get(layout_name) if layout_name in doc.layouts else doc.layouts.new(layout_name)
        )
        layout.add_blockref(block.name, (0, 0)).add_auto_attribs(attributes)
    path.parent.mkdir(parents=True, exist_ok=True)
    doc.saveas(path)
    return path


class DxfReader:
    """The tests' title block reader: reads a made-up DXF (named .dwg) the way accoreconsole's dump reads a DWG."""

    id = "dxf-test-1"

    def __init__(self):
        self.read_paths: list[Path] = []

    def read(self, path: Path, work: Path | None = None) -> list[BlockInsert]:
        self.read_paths.append(path)
        try:
            doc = ezdxf.readfile(path)
        except (OSError, ezdxf.DXFError):
            return []
        out = []
        for layout in doc.layouts:
            for insert in layout.query("INSERT"):
                if insert.attribs:
                    out.append(BlockInsert(layout.name, insert.dxf.name,
                                           {a.dxf.tag: a.dxf.text for a in insert.attribs}))
        return out


def make_dwg_with_preview(path: Path, image: Image.Image, kind: str = "png") -> Path:
    """Bytes laid out like a DWG's header and preview section (R2018, 'AC1032'), with a PNG or BMP preview."""
    if kind == "png":
        buf = io.BytesIO()
        image.save(buf, format="PNG")
        data, code = buf.getvalue(), 6
    else:
        buf = io.BytesIO()
        image.convert("RGB").save(buf, format="BMP")
        data, code = buf.getvalue()[14:], 2  # a DIB: the BMP without its file header
    header = bytearray(b"AC1032" + b"\0" * 0x80)
    seeker = 0x100
    struct.pack_into("<i", header, 0x0D, seeker)
    body = bytearray(header.ljust(seeker, b"\0"))
    table_start = seeker + 16 + 4 + 1
    header_entry_start = table_start + 2 * 9
    image_start = header_entry_start + 80
    body += PREVIEW_SENTINEL + struct.pack("<i", 0) + bytes([2])
    body += struct.pack("<Bii", 1, header_entry_start, 80)
    body += struct.pack("<Bii", code, image_start, len(data))
    body += b"\0" * 80 + data
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(body))
    return path


def touch(path: Path, seconds: float) -> None:
    os.utime(path, (seconds, seconds))


PLANT = "Projects/Made-up Plant Upgrade"
SCHOOL = "Projects/Made-up School Addition"


def small_tree(root: Path) -> None:
    """A made-up Dropbox: a DWG with its plot, a DWG with no PDF, a vendor PDF with no DWG, and a second project."""
    make_dxf(root / PLANT / "CAD" / "E-201.dwg", [("Layout1", {
        "DWG_NO": "E-201", "TITLE": "Boiler room power plan", "REV": "A", "SCALE": '1/4" = 1\'-0"', "DATE": "2026-10-02"})])
    title_block_pdf(root / PLANT / "PDF" / "E-201.pdf", number="E-201", title="Boiler room power plan", rev="A",
                    scale='1/4" = 1\'-0"', date="2026-10-02", title_meta="E-201-Layout1")
    make_dxf(root / PLANT / "CAD" / "E-202.dwg", [("Layout1", {
        "DWG_NO": "E-202", "TITLE": "Boiler room lighting plan", "REV": "0", "SCALE": '1/4" = 1\'-0"'})])
    title_block_pdf(root / PLANT / "Vendor" / "V-12 Pump skid GA.pdf", number="V-12",
                    title="Pump skid general arrangement", rev="2", scale="1:20", date="2026-09-30",
                    inches=(17, 11))
    make_dxf(root / SCHOOL / "Mechanical" / "M-101.dwg", [("Layout1", {
        "DWGNO": "M-101", "TITLE": "First floor HVAC plan", "REV": "C", "SCALE": '1/4" = 1\'-0"', "DATE": "2026-10-12"})])
    title_block_pdf(root / SCHOOL / "Mechanical" / "M-101.pdf", number="M-101", title="First floor HVAC plan", rev="C",
                    scale='1/4" = 1\'-0"', date="2026-10-12")
    (root / SCHOOL / "Mechanical" / "M-101.dwl").write_bytes(b"lock")
    (root / SCHOOL / "notes.txt").write_text("made up")
    for i, p in enumerate(sorted(q for q in root.rglob("*") if q.is_file())):
        touch(p, 1_790_000_000 + i * 60)


class ScriptedDropbox:
    """A made-up Dropbox server for the Dropbox client's transport: issues made-up tokens, serves made-up files from a
    snapshot of the made-up Dropbox folder taken when it is made (the server's copy, not the laptop's), and fails on
    cue. No network."""

    APP_KEY = "madeupappkey0000"
    REFRESH = "made-up-refresh-token-7c1f"
    CODE = "made-up-code-0042"

    def __init__(self, root: Path):
        import hashlib

        self.files = {}
        for p in root.rglob("*"):
            if p.is_file() and "Vellum" not in p.relative_to(root).parts[:1]:
                self.files["/" + p.relative_to(root).as_posix()] = p.read_bytes()
        self.hashlib = hashlib
        self.issued: list[str] = []
        self.downloads: list[str] = []
        self.fail: list[int] = []  # statuses the next downloads answer with
        self.revoked = 0
        self.calls = 0

    def update(self, db_path: str, data: bytes) -> None:
        self.files[db_path] = data

    def content_hash(self, data: bytes) -> str:
        h = self.hashlib
        blocks = b"".join(h.sha256(data[i:i + 4 * 1024 * 1024]).digest() for i in range(0, len(data), 4 * 1024 * 1024))
        return h.sha256(blocks).hexdigest()

    def __call__(self, url, headers, body):
        import json
        import urllib.parse

        from vellum_indexer.dropbox_api import DOWNLOAD_URL, REVOKE_URL, TOKEN_URL, Response

        self.calls += 1
        if url == TOKEN_URL:
            form = dict(urllib.parse.parse_qsl(body.decode()))
            ok = form.get("client_id") == self.APP_KEY and (
                (form.get("grant_type") == "refresh_token" and form.get("refresh_token") == self.REFRESH)
                or (form.get("grant_type") == "authorization_code" and form.get("code") == self.CODE
                    and form.get("code_verifier")))
            if not ok:
                return Response(400, {}, io.BytesIO(b'{"error": "invalid_grant"}'))
            access = f"made-up-access-token-{len(self.issued):04}"
            self.issued.append(access)
            reply = {"access_token": access, "expires_in": 14400, "token_type": "bearer"}
            if form["grant_type"] == "authorization_code":
                reply["refresh_token"] = self.REFRESH
            return Response(200, {}, io.BytesIO(json.dumps(reply).encode()))
        if url == REVOKE_URL:
            self.revoked += 1
            return Response(200, {}, io.BytesIO(b"null"))
        if url == DOWNLOAD_URL:
            token = headers.get("Authorization", "").removeprefix("Bearer ")
            if token not in self.issued[-1:]:
                return Response(401, {}, io.BytesIO(b'{"error": "expired_access_token"}'))
            if self.fail:
                status = self.fail.pop(0)
                return Response(status, {"retry-after": "1"} if status == 429 else {}, io.BytesIO(b"{}"))
            path = json.loads(headers["Dropbox-API-Arg"])["path"]
            data = self.files.get(path)
            if data is None:
                return Response(409, {}, io.BytesIO(b'{"error_summary": "path/not_found/"}'))
            self.downloads.append(path)
            result = {"size": len(data), "content_hash": self.content_hash(data), "path_display": path}
            return Response(200, {"dropbox-api-result": json.dumps(result)}, io.BytesIO(data))
        return Response(404, {}, io.BytesIO(b""))
