"""A stand-in for accoreconsole.exe's plot, for the tests: it takes the same arguments, reads the script's
(vellum-plot ...) call, reads the layout's saved page setup from the made-up DXF copy (ezdxf), and does what the LISP
in plot.py does: reports the setup, makes relative xref, image and underlay paths absolute against the original's
folder and reports each one and whether it is there, then plots (writes a made-up PDF at the paper's size) or says
UNUSABLE.

usage: python fake_plot_console.py <mode> /i <copy> /s <script> /l en-US
mode: ok | hang | nopdf | wrongpdf. Each run is logged, one JSON line, to $VELLUM_FAKE_PLOT_LOG if set.
"""

import json
import os
import pathlib
import re
import sys
import time

sys.path[:0] = [str(pathlib.Path(__file__).parent)]

mode, args = sys.argv[1], sys.argv[2:]
drawing = pathlib.Path(args[args.index("/i") + 1])
script = pathlib.Path(args[args.index("/s") + 1]).read_text(encoding="utf-8")
call = re.search(r'^\(vellum-plot ((?:"[^"]*" ?){8})\)$', script, re.M)
layout, out, info, plot_mode, sheet, units, orient, folder = re.findall(r'"([^"]*)"', call.group(1))
(drawing.parent / (drawing.stem + ".dwl")).write_text("lock")  # AutoCAD's lock file, beside what it opened
log = os.environ.get("VELLUM_FAKE_PLOT_LOG")
if log:
    with open(log, "a", encoding="utf-8") as f:
        f.write(json.dumps({"drawing": str(drawing), "layout": layout, "mode": plot_mode, "sheet": sheet,
                            "units": units, "orient": orient, "folder": folder, "cwd": os.getcwd(),
                            "script": script}) + "\n")
if mode == "hang":
    time.sleep(60)

import ezdxf  # noqa: E402

from makers import make_pdf  # noqa: E402

doc = ezdxf.readfile(drawing)
lines = []
found = None
wanted = layout or doc.layouts.active_layout().name
for lay in doc.layouts:
    if lay.name.lower() == wanted.lower():
        found = lay
if found is None:
    lines.append("NOLAYOUT")
else:
    d = found.dxf_layout.dxf
    dev = d.plot_configuration_file or ""
    lines.append("\t".join(["SETUP", found.name, dev, d.paper_size or "", f"{d.paper_width:.2f}",
                            f"{d.paper_height:.2f}", str(d.plot_rotation)]))

    def absolute(p):  # vellum-abs
        if not p or p[1:2] == ":" or p[:1] in ("\\", "/"):
            return p
        return folder + "/" + p

    def there(p):
        return os.path.exists(p.replace("\\", "/")) if os.sep == "/" else os.path.exists(p)

    for blk in doc.blocks:  # top-level xrefs: re-pathed, then resolved or not
        if blk.block_record.is_xref and "|" not in blk.name:
            a = absolute(blk.block.dxf.xref_path)
            lines.append("\t".join(["REF", "xref", a, "1" if there(a) else "0"]))
    kinds = {"IMAGEDEF": "image", "PDFDEFINITION": "pdf", "DWFDEFINITION": "dwf", "DGNDEFINITION": "dgn"}
    for obj in doc.objects:
        if obj.dxftype() in kinds and obj.dxf.hasattr("filename"):
            a = absolute(obj.dxf.filename)
            lines.append("\t".join(["REF", kinds[obj.dxftype()], a, "1" if there(a) else "0"]))
    usable = dev.upper().endswith(".PC3") and "PDF" in dev.upper()
    if plot_mode == "saved" and not usable:
        lines.append("UNUSABLE")
    else:
        if mode == "wrongpdf":
            pathlib.Path(out).write_bytes(b"not a PDF")
        elif mode != "nopdf":
            w, h = d.paper_width / 25.4, d.paper_height / 25.4
            make_pdf(pathlib.Path(out), [(72, 72, 12, f"Made-up plot of {found.name}")], title=found.name,
                     inches=(max(w, h), min(w, h)) if orient in ("_L", "") else (min(w, h), max(w, h)))
        lines.append("PLOTTED")
lines.append("END")
pathlib.Path(info).write_text("\n".join(lines) + "\n", encoding="utf-8")
