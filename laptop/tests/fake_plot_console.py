"""A stand-in for accoreconsole.exe's plot, for the tests: it takes the same arguments, reads the script's
(vellum-plot ...) call, reads the layout's saved page setup from the made-up DXF copy (ezdxf), and does what the LISP
in plot.py does: reports the setup, makes relative xref, image and underlay paths absolute against the original's
folder and reports each one and whether it is there, then plots (writes a made-up PDF at the paper's size) or says
UNUSABLE.

It answers ``-PLOT`` the way AutoCAD 2026 does. It takes the answers the script's LISP gives ``-PLOT`` for the mode it
was called with and walks them through the prompts AutoCAD asks, which differ between the Model tab and a paper
layout (the prompt lists below, the Model tab's taken from the real console, #87). An answer a prompt can't take, or
too few or too many answers, cancels the function as AutoCAD does: "PLOTTED" is never written. A script whose LISP
catches that error in an *error* handler then writes "FAILED" and "END"; one that doesn't writes neither. Either way
the console then sits, as the real one did, until it is stopped.

It refuses what AutoCAD 2026's console refuses (#87): ``(command ...)`` called inside ``vl-catch-all-apply`` fails
with "bad order function: COMMAND" instead of plotting (the LISP's catch then reports it), and so does a command
called from ``*error*``, which then never finishes its report. The stand-in can't run LISP, so it looks for those
constructs in the script's text.

usage: python fake_plot_console.py <mode> /i <copy> /s <script> /l en-US
mode: ok | hang | nopdf | wrongpdf | linger (plots, writes END, then doesn't quit). Each run is logged, one JSON line,
to $VELLUM_FAKE_PLOT_LOG if set, with the answers -PLOT was given.
"""

import json
import os
import pathlib
import re
import sys
import time

sys.path[:0] = [str(pathlib.Path(__file__).parent)]

SIT = float(os.environ.get("VELLUM_FAKE_PLOT_SIT", "60"))  # how long a console that won't quit sits, in seconds
BAD_ORDER = "bad order function: COMMAND"
CALLS_COMMAND = re.compile(r"\(command[ )]|'command\b|\bvl-cmdf\b|\(function command\)")


def forms_starting(script, head):
    """Every balanced form in the script that starts with ``head`` (strings skipped), as text."""
    found = []
    for m in re.finditer(re.escape(head), script):
        depth, i, in_string = 0, m.start(), False
        while i < len(script):
            c = script[i]
            if in_string:
                if c == "\\":
                    i += 1
                elif c == '"':
                    in_string = False
            elif c == '"':
                in_string = True
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    found.append(script[m.start():i + 1])
                    break
            i += 1
    return found


def command_in_catch(script):
    """A command called inside vl-catch-all-apply, which AutoCAD refuses."""
    return any(CALLS_COMMAND.search(f) for f in forms_starting(script, "(vl-catch-all-apply"))


def command_in_error(script):
    """A command called from an *error* handler, which AutoCAD refuses."""
    return any(CALLS_COMMAND.search(f) for f in forms_starting(script, "(setq *error*")
               + forms_starting(script, "(defun *error*"))


def yes_no(a):
    return a.lstrip("_").upper() in ("", "Y", "N", "YES", "NO")


def keyword(*letters):
    return lambda a: a == "" or a.lstrip("_")[:1].upper() in letters


def anything(a):
    return True


def scale(a):
    return a == "" or a.lstrip("_").upper() in ("F", "FIT") or re.fullmatch(r"[\d.]+\s*[:=]\s*[\d.]+", a) is not None


def offset(a):
    return a == "" or a.lstrip("_").upper() in ("C", "CENTER") or re.fullmatch(r"-?[\d.]+,-?[\d.]+", a) is not None


def layout_name(name):
    return lambda a: a == "" or a.lower() == name.lower()


def prompts(detailed, model, name):
    """AutoCAD 2026's -PLOT prompts after "Detailed plot configuration?", each with what it takes."""
    if not detailed:
        return [("Enter a layout name or [?]", layout_name(name)), ("Enter a page setup name", anything),
                ("Enter an output device name or [?]", anything), ("Enter file name", anything),
                ("Save changes to page setup [Yes/No]?", yes_no), ("Proceed with plot [Yes/No]", yes_no)]
    head = [("Enter a layout name or [?]", layout_name(name)), ("Enter an output device name or [?]", anything),
            ("Enter paper size or [?]", anything), ("Enter paper units [Inches/Millimeters]", keyword("I", "M")),
            ("Enter drawing orientation [Portrait/Landscape]", keyword("P", "L")),
            ("Plot upside down? [Yes/No]", yes_no)]
    if model:
        middle = [("Enter plot area [Display/Extents/Limits/View/Window]", keyword("D", "E", "L", "V", "W"))]
    else:
        middle = [("Enter plot area [Display/Extents/Layout/View/Window]", keyword("D", "E", "L", "V", "W"))]
    middle += [("Enter plot scale or [Fit]", scale), ("Enter plot offset (x,y) or [Center]", offset),
               ("Plot with plot styles? [Yes/No]", yes_no), ("Enter plot style table name or [?]", anything),
               ("Plot with lineweights? [Yes/No]", yes_no)]
    if model:
        middle += [("Enter shade plot setting [As displayed/legacy Wireframe/legacy Hidden/Visual styles/Rendered]",
                    keyword("A", "W", "H", "V", "R"))]
    else:
        middle += [("Scale lineweights with plot scale? [Yes/No]", yes_no), ("Plot paper space first? [Yes/No]", yes_no),
                   ("Hide paperspace objects? [Yes/No]", yes_no)]
    tail = [("Enter file name", anything), ("Save changes to page setup [Yes/No]?", yes_no),
            ("Proceed with plot [Yes/No]", yes_no)]
    return head + middle + tail


def plot_answers(script, plot_mode):
    """The answers the script's vellum-plot gives -PLOT in this mode: the -PLOT list under the cond clause
    ``((= mode "<mode>") ...``, else the one under ``(T ...``."""
    clauses = [(m.start(), m.group(1) or "T") for m in re.finditer(r'\(\(= mode "(\w+)"\)|\(T ', script)]
    lists = []
    for m in re.finditer(r'"_\.-PLOT"((?: (?:"[^"]*"|[a-z][a-z-]*))*)\)', script):
        guard = [c for at, c in clauses if at < m.start()]
        lists.append((guard[-1] if guard else "T", re.findall(r'"[^"]*"|[a-z][a-z-]*', m.group(1))))
    chosen = [a for g, a in lists if g == plot_mode] or [a for g, a in lists if g == "T"]
    return chosen[0]


def sit():
    time.sleep(SIT)
    sys.exit(0)


def main():
    mode, args = sys.argv[1], sys.argv[2:]
    drawing = pathlib.Path(args[args.index("/i") + 1])
    script = pathlib.Path(args[args.index("/s") + 1]).read_text(encoding="utf-8")
    call = re.search(r'^\(vellum-plot ((?:"[^"]*" ?){8})\)$', script, re.M)
    layout, out, info, plot_mode, sheet, units, orient, folder = re.findall(r'"([^"]*)"', call.group(1))
    (drawing.parent / (drawing.stem + ".dwl")).write_text("lock")  # AutoCAD's lock file, beside what it opened
    log = os.environ.get("VELLUM_FAKE_PLOT_LOG")
    if mode == "hang":
        if log:
            with open(log, "a", encoding="utf-8") as f:
                f.write(json.dumps({"drawing": str(drawing), "layout": layout, "mode": plot_mode, "sheet": sheet,
                                    "units": units, "orient": orient, "folder": folder, "cwd": os.getcwd(),
                                    "script": script, "answers": None}) + "\n")
        sit()

    import ezdxf

    from makers import make_pdf

    doc = ezdxf.readfile(drawing)
    lines = []
    found = None
    answers = None
    cancelled = False
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
            values = {"name": found.name, "out": out, "sheet": sheet, "units": units, "orient": orient, "dev": dev}
            given = plot_answers(script, plot_mode)
            answers = [a[1:-1] if a.startswith('"') else values[a] for a in given]
            detailed = answers[:1] and answers[0].lstrip("_").upper() in ("Y", "YES")
            asked = prompts(detailed, found.name.lower() == "model", found.name)
            cancelled = len(answers) - 1 != len(asked) or not all(
                takes(answer) for (_, takes), answer in zip(asked, answers[1:], strict=False))
            if command_in_catch(script):  # refused before it asks anything; the catch reports it
                print(BAD_ORDER)
                lines.append(f"FAILED\t{BAD_ORDER}")
                cancelled = False
            elif cancelled:  # "; error: Function cancelled"
                if command_in_error(script):
                    print(BAD_ORDER)  # the handler stops at its command, its report never finished
                    lines = []
                elif "*error*" in script:
                    lines.append("FAILED\tFunction cancelled")
                else:
                    lines = []  # the LISP stopped before it wrote or closed its report
            else:
                if mode == "wrongpdf":
                    pathlib.Path(out).write_bytes(b"not a PDF")
                elif mode != "nopdf":
                    w, h = d.paper_width / 25.4, d.paper_height / 25.4
                    make_pdf(pathlib.Path(out), [(72, 72, 12, f"Made-up plot of {found.name}")], title=found.name,
                             inches=(max(w, h), min(w, h)) if orient in ("_L", "") else (min(w, h), max(w, h)))
                lines.append("PLOTTED")
    if log:
        with open(log, "a", encoding="utf-8") as f:
            f.write(json.dumps({"drawing": str(drawing), "layout": layout, "mode": plot_mode, "sheet": sheet,
                                "units": units, "orient": orient, "folder": folder, "cwd": os.getcwd(),
                                "script": script, "answers": answers}) + "\n")
    if lines:
        lines.append("END")
        pathlib.Path(info).write_text("\n".join(lines) + "\n", encoding="utf-8")
    if cancelled or mode == "linger":
        sit()  # the real console sat after the cancel, its command still waiting


if __name__ == "__main__":
    main()
