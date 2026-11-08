"""Plotting a DWG to PDF when the Duo asks (#67): the request format, the answers, the plot through a stand-in for
AutoCAD's core console, where the PDF goes, the index listing it, the check-in and the cleanup. Every drawing is made
up by the test."""

import calendar
import json
import os
import sys
import threading
import time
import uuid
from pathlib import Path

import pytest

from vellum_indexer import plot_requests as pr
from vellum_indexer.index import read_index
from vellum_indexer.plot import (
    AccoreconsolePlotter,
    PlotError,
    fallback_sheet,
    is_pdf_device,
    landscape,
    lisp_string,
    plot_name,
    plot_script,
    safe_part,
)
from vellum_indexer.plot_requests import CheckIn, NotYet, PlotFolder, Refused, decode, request_name

from makers import PLANT, make_dxf, make_pdf, small_tree, touch
from test_incremental import budget

FAKE = Path(__file__).parent / "fake_plot_console.py"
ARCH_D = {"device": "DWG To PDF.pc3", "media": "ARCH_full_bleed_D_(24.00_x_36.00_Inches)", "size": (914.4, 609.6)}


def plotter(tmp_path: Path, mode: str = "ok", timeout: float = 60) -> AccoreconsolePlotter:
    return AccoreconsolePlotter([sys.executable, str(FAKE), mode], tmp_path / "home" / "work", timeout=timeout)


@pytest.fixture
def plot_log(tmp_path, monkeypatch):
    path = tmp_path / "fake-plot-log.jsonl"
    monkeypatch.setenv("VELLUM_FAKE_PLOT_LOG", str(path))

    def runs():
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    return runs


def requests_folder(dropbox: Path) -> Path:
    return dropbox / "Vellum" / "Plots" / "requests"


def ask(dropbox: Path, entry: dict, name: str | None = None, **override) -> str:
    """Write a request as the Duo would: one file named by a fresh UUID."""
    name = name or str(uuid.uuid4()).upper()
    body = {"format": 1, "id": entry["id"], "path": entry["dwg"]["path"], "layout": entry["layout"],
            "asked": "2026-11-07T12:00:00Z", **override}
    folder = requests_folder(dropbox)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{name}.json").write_text(json.dumps(body), encoding="utf-8")
    return name


def answer_of(dropbox: Path, name: str) -> dict | None:
    path = requests_folder(dropbox) / f"{name}.answer.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def entries(dropbox: Path) -> dict[str, dict]:
    return {(e["name"], e["layout"]): e for e in read_index(dropbox / "Vellum" / "Index")[1]}


def answer_now(indexer) -> int:
    """Turns until every waiting request is answered (one plot a turn)."""
    indexer.plot_wanted.set()
    answered = 0
    for _ in range(50):
        answered += indexer.answer_plot_requests()
        if not indexer.plot_wanted.is_set():
            break
    return answered


def spy_answers(indexer) -> list[tuple[str, str]]:
    seen = []
    real = indexer.plot_folder.answer

    def spy(answer):
        seen.append((answer.request, answer.state))
        real(answer)

    indexer.plot_folder.answer = spy
    return seen


# --- The request format ------------------------------------------------------------------------------------------

GOOD = {"format": 1, "id": "dd0bdad0ab9b9082", "path": "/Projects/Made-up/CAD/E-201.dwg", "layout": "Layout1",
        "asked": "2026-11-07T12:00:00Z"}


def test_a_request_decodes():
    r = decode("6F1C2B9A-0D3E-4A5B-8C7D-1E2F3A4B5C6D", json.dumps(GOOD).encode())
    assert (r.id, r.path, r.layout, r.asked) == (GOOD["id"], GOOD["path"], "Layout1", GOOD["asked"])
    assert decode("abcdefgh", json.dumps({**GOOD, "layout": None, "extra": "ignored"}).encode()).layout is None


@pytest.mark.parametrize("change, reason", [
    ({"format": 2}, "format 2"),
    ({"format": None}, "format None"),
    ({"id": "DD0BDAD0AB9B9082"}, "no drawing index entry"),
    ({"id": "dd0bdad0ab9b9082#layout1"}, "no drawing index entry"),
    ({"path": "Projects/E-201.dwg"}, "no DWG"),
    ({"path": "/Projects/E-201.pdf"}, "no DWG"),
    ({"path": "/Projects/../../Windows/E-201.dwg"}, "isn't a Dropbox path"),
    ({"path": "/Projects/./E-201.dwg"}, "isn't a Dropbox path"),
    ({"path": "/Projects\\..\\E-201.dwg"}, "isn't a Dropbox path"),
    ({"path": "/" + "a" * 1100 + ".dwg"}, "isn't a Dropbox path"),
    ({"layout": 7}, "isn't a layout name"),
    ({"layout": ""}, "isn't a layout name"),
    ({"asked": "yesterday"}, "when it was asked"),
    ({"asked": None}, "when it was asked"),
])
def test_a_bad_request_is_refused_with_a_reason(change, reason):
    with pytest.raises(Refused, match=reason.replace("\\", "\\\\")):
        decode("abcdefgh", json.dumps({**GOOD, **change}).encode())


def test_unreadable_requests_are_refused_once_settled_and_waited_for_while_arriving():
    for data in (b"{not json", b"[1, 2]", b"\xff\xfe\x00", json.dumps("a string").encode()):
        with pytest.raises(Refused, match="couldn't be read"):
            decode("abcdefgh", data, age_seconds=60)
    with pytest.raises(NotYet):
        decode("abcdefgh", b'{"format": 1, "id"', age_seconds=1)
    with pytest.raises(Refused, match="too big"):
        decode("abcdefgh", b" " * 5000, age_seconds=60)


@pytest.mark.parametrize("file_name, name", [
    ("6F1C2B9A-0D3E-4A5B-8C7D-1E2F3A4B5C6D.json", "6F1C2B9A-0D3E-4A5B-8C7D-1E2F3A4B5C6D"),
    ("6f1c2b9a.json", "6f1c2b9a"),
    ("6F1C2B9A-0D3E-4A5B-8C7D-1E2F3A4B5C6D.answer.json", None),
    ("~$6F1C2B9A.json.123.tmp", None),
    ("short.json", None),
    ("../../escape.json", None),
    ("has space.json", None),
    ("6F1C2B9A.txt", None),
])
def test_which_files_are_requests(file_name, name):
    assert request_name(file_name) == name


# --- The page setup and the script -------------------------------------------------------------------------------

def test_the_fallback_sheet_is_dwg_to_pdfs_for_the_layouts_paper():
    assert fallback_sheet(914.4, 609.6) == ("ARCH full bleed D (24.00 x 36.00 Inches)", "Inches")
    assert fallback_sheet(420, 297) == ("ISO full bleed A3 (297.00 x 420.00 MM)", "Millimeters")
    assert fallback_sheet(279.4, 431.8) == ("ANSI full bleed B (11.00 x 17.00 Inches)", "Inches")
    assert fallback_sheet(500, 700) is None
    assert is_pdf_device("DWG To PDF.pc3") and is_pdf_device("AutoCAD PDF (High Quality Print).pc3")
    assert not is_pdf_device("None") and not is_pdf_device("") and not is_pdf_device("\\\\office\\HP DesignJet")
    assert not is_pdf_device("PDF printer")  # a Windows printer, not a .pc3 that writes a file
    assert landscape(914.4, 609.6, 0) and not landscape(609.6, 914.4, 0) and landscape(609.6, 914.4, 1)


def test_the_script_types_only_what_the_indexer_chose_and_never_saves(tmp_path):
    origin = tmp_path / "Dropbox" / "Projects" / "Made-up" / "CAD"
    script = plot_script("E-201 Power", tmp_path / "saved.pdf", tmp_path / "saved.txt", folder=origin)
    lines = script.splitlines()
    assert [line.split(" ")[1] for line in lines[:5]] == ["vellum-pclean", "vellum-abs", "vellum-refs",
                                                          "vellum-plot-done", "vellum-plot"]
    for line in lines[:5]:
        assert line.startswith("(defun ") and line.count("(") == line.count(")")
    assert lines[5] == (f'(vellum-plot "E-201 Power" "{(tmp_path / "saved.pdf").as_posix()}" '
                        f'"{(tmp_path / "saved.txt").as_posix()}" "saved" "" "_I" "_L" "{origin.as_posix()}")')
    assert lines[6:] == ["_.QUIT", "_Y"]
    lowered = script.lower()
    for word in ("qsave", "saveas", "wblock", "(load", "appload", ".lsp", "secureload", "setvar"):
        assert word not in lowered
    # the -PLOT answers "No" to saving its settings into the page setup, in both modes
    assert '"_.-PLOT" "_N" name "" "" out "_N" "_Y"' in script
    assert 'out "_N" "_Y")' in script.split('"DWG To PDF.pc3"')[1]
    for hostile in ('E-201" ) (command "_.ERASE', "E-201\\", "E-201\n_.QSAVE", "E\x00"):
        with pytest.raises(PlotError, match="can't be typed"):
            lisp_string(hostile)


# --- Where a plot goes -------------------------------------------------------------------------------------------

def test_a_plots_name_says_its_project_and_drawing_and_never_clashes():
    t = 1_790_000_000 * 10**9
    a = plot_name("Made-up Plant Upgrade", "/Projects/Made-up Plant Upgrade/CAD/E-201.dwg", "Layout1", t)
    assert a.startswith("/Vellum/Plots/Made-up Plant Upgrade/E-201 - Layout1 - 2026-09-21 ")
    assert a.endswith(".pdf") and len(a.rsplit(" - ", 1)[1]) == len("0123abcd.pdf")
    others = {
        plot_name("Made-up Plant Upgrade", "/Projects/Made-up Plant Upgrade/CAD/E-201.dwg", "Layout2", t),
        plot_name("Made-up Plant Upgrade", "/Projects/Made-up Plant Upgrade/Old/E-201.dwg", "Layout1", t),
        plot_name("Made-up Plant Upgrade", "/Projects/Made-up Plant Upgrade/CAD/E-201.dwg", "Layout1", t + 10**9),
    }
    assert a not in others and len(others) == 3
    assert plot_name(None, "/E-9.dwg", None, t).startswith("/Vellum/Plots/No project/E-9 - 2026-09-21 ")
    assert safe_part('a<b>:"c"/d\\e|f?g*') == "a_b___c__d_e_f_g_"
    assert safe_part("..~$x. ") == "x" and safe_part("CON") == "_CON" and safe_part("...") == "_"
    assert safe_part("../../etc") == "_.._etc" and safe_part("..") == "_"  # one name part, never a way up


# --- The state machine, through the indexer ----------------------------------------------------------------------

def test_a_request_is_answered_plotting_then_done_and_the_index_lists_the_pdf(dropbox, tmp_path, make_indexer, plot_log):
    small_tree(dropbox)
    make_dxf(dropbox / PLANT / "CAD" / "E-301.dwg", [("Layout1", {"DWG_NO": "E-301", "TITLE": "Made-up cable plan"})],
             setups={"Layout1": ARCH_D})
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    entry = entries(dropbox)[("E-301.dwg", "Layout1")]
    assert entry["pdf"] is None
    name = ask(dropbox, entry)
    states = spy_answers(indexer)
    assert answer_now(indexer) == 1
    assert states == [(name, "plotting"), (name, "done")]
    answer = answer_of(dropbox, name)
    assert answer["state"] == "done" and answer["format"] == 1 and answer["request"] == name
    assert answer["id"] == entry["id"] and answer["pageSetup"] == "saved" and answer["reason"] is None
    assert answer["fitted"] is False and "fitted" not in entries(dropbox)[("E-301.dwg", "Layout1")]["pdf"]
    assert answer["pdf"].startswith("/Vellum/Plots/Made-up Plant Upgrade/E-301 - Layout1 - ")
    pdf = dropbox / answer["pdf"].lstrip("/")
    assert pdf.read_bytes().startswith(b"%PDF")
    listed = entries(dropbox)[("E-301.dwg", "Layout1")]
    assert listed["pdf"]["path"] == answer["pdf"] and listed["pairedBy"] == "plotted"
    assert listed["pdf"]["contentHash"] == answer["contentHash"] and len(answer["contentHash"]) == 64
    assert listed["pdf"]["paperInches"] == [36.0, 24.0] and listed["pdf"]["read"] is True
    assert listed["thumbnail"] and (dropbox / "Vellum" / "Index" / "thumbnails" / listed["thumbnail"]).exists()
    assert listed["path"] == entry["path"] and listed["dwg"] == entry["dwg"] and listed["otherPdfs"] == []
    assert len(plot_log()) == budget("plot_console_runs_with_page_setup") == 1  # one run, with its own page setup

    # answered: not plotted again, at the next look or after a restart
    assert answer_now(indexer) == 0 and len(plot_log()) == 1
    indexer.scan()
    assert len(plot_log()) == 1 and entries(dropbox)[("E-301.dwg", "Layout1")]["pdf"]["path"] == answer["pdf"]


def test_a_request_a_stop_interrupted_is_plotted_again(dropbox, tmp_path, make_indexer, plot_log):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    name = ask(dropbox, entries(dropbox)[("E-202.dwg", "Layout1")])
    PlotFolder(dropbox / "Vellum" / "Plots").answer(pr.Answer(name, "plotting"))  # the laptop stopped part way
    assert answer_now(indexer) == 1 and answer_of(dropbox, name)["state"] == "done"


def test_a_layout_with_no_pdf_page_setup_falls_back_to_dwg_to_pdf_at_its_paper_size(dropbox, tmp_path, make_indexer,
                                                                                       plot_log):
    small_tree(dropbox)  # E-202's Layout1 has no plotter saved and A3 paper, as ezdxf makes it
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    name = ask(dropbox, entries(dropbox)[("E-202.dwg", "Layout1")])
    answer_now(indexer)
    answer = answer_of(dropbox, name)
    assert answer["state"] == "done" and answer["pageSetup"] == "fallback"
    assert "DWG To PDF" in answer["reason"] and "no page setup" in answer["reason"]
    runs = plot_log()
    assert [r["mode"] for r in runs] == ["saved", "fallback"]
    assert len(runs) == budget("plot_console_runs_fallback")
    assert (runs[1]["sheet"], runs[1]["units"], runs[1]["orient"]) == ("ISO full bleed A3 (297.00 x 420.00 MM)", "_M",
                                                                       "_L")


def test_a_paper_size_dwg_to_pdf_has_not_got_fails_rather_than_guessing(dropbox, tmp_path, make_indexer, plot_log):
    make_dxf(dropbox / PLANT / "CAD" / "E-401.dwg", [("Layout1", {"DWG_NO": "E-401"})],
             setups={"Layout1": {"device": "None", "size": (500, 700)}})
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    name = ask(dropbox, entries(dropbox)[("E-401.dwg", "Layout1")])
    answer_now(indexer)
    answer = answer_of(dropbox, name)
    assert answer["state"] == "failed" and answer["pdf"] is None
    assert answer["reason"] == ("the layout has no page setup that plots to PDF, and its paper size (500 x 700 mm) "
                                "isn't one DWG To PDF has")
    assert [r["mode"] for r in plot_log()] == ["saved"]


@pytest.mark.parametrize("mode, reason", [
    ("hang", "timed out: AutoCAD took longer than 2 seconds, so the plot was stopped"),
    ("nopdf", "AutoCAD made no PDF from the layout's page setup"),
    ("wrongpdf", "AutoCAD made no PDF from the layout's page setup"),
])
def test_a_hung_or_failed_console_is_answered_failed(dropbox, tmp_path, make_indexer, plot_log, mode, reason):
    make_dxf(dropbox / PLANT / "CAD" / "E-301.dwg", [("Layout1", {"DWG_NO": "E-301"})], setups={"Layout1": ARCH_D})
    indexer = make_indexer(plotter=plotter(tmp_path, mode, timeout=2))
    indexer.scan()
    name = ask(dropbox, entries(dropbox)[("E-301.dwg", "Layout1")])
    started = time.monotonic()
    answer_now(indexer)
    assert time.monotonic() - started < 20
    answer = answer_of(dropbox, name)
    assert (answer["state"], answer["reason"], answer["pdf"]) == ("failed", reason, None)
    assert not (dropbox / "Vellum" / "Plots" / "Made-up Plant Upgrade").exists()
    assert list((tmp_path / "home" / "work").iterdir()) == []  # the job folder is emptied either way
    assert entries(dropbox)[("E-301.dwg", "Layout1")]["pdf"] is None


def test_with_no_autocad_the_answer_says_so(dropbox, make_indexer):
    small_tree(dropbox)
    indexer = make_indexer()  # no plotter: NoPlotter
    indexer.scan()
    name = ask(dropbox, entries(dropbox)[("E-202.dwg", "Layout1")])
    answer_now(indexer)
    assert answer_of(dropbox, name)["reason"] == "AutoCAD isn't installed on the laptop"


@pytest.mark.parametrize("override, reason", [
    ({"path": "/Projects/Made-up Plant Upgrade/CAD/Nowhere.dwg"}, "isn't in the drawing index"),
    ({"path": "/Vellum/Plots/x.dwg"}, "isn't in the drawing index"),
    ({"layout": "Layout9"}, "doesn't match the drawing index"),
    ({"id": "0123456789abcdef"}, "doesn't match the drawing index"),
    ({"path": "/Projects/../Projects/Made-up Plant Upgrade/CAD/E-202.dwg"}, "isn't a Dropbox path"),
    ({"format": 3}, "plot request format 1"),
])
def test_a_request_the_index_does_not_hold_is_refused(dropbox, tmp_path, make_indexer, plot_log, override, reason):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    name = ask(dropbox, entries(dropbox)[("E-202.dwg", "Layout1")], **override)
    answer_now(indexer)
    answer = answer_of(dropbox, name)
    assert answer["state"] == "failed" and reason in answer["reason"]
    assert plot_log() == []  # AutoCAD never started


def test_a_request_for_a_pdf_entry_or_garbage_is_refused_and_a_half_arrived_one_waits(dropbox, tmp_path,
                                                                                       make_indexer, plot_log):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    folder = requests_folder(dropbox)
    folder.mkdir(parents=True)
    (folder / "AAAAAAAA-garbage.json").write_bytes(b"\x00\x01 not json")
    old = time.time() - 3600
    os.utime(folder / "AAAAAAAA-garbage.json", (old, old))
    (folder / "BBBBBBBB-arriving.json").write_bytes(b'{"format": 1, "id": "dd')
    answer_now(indexer)
    assert answer_of(dropbox, "AAAAAAAA-garbage")["reason"] == "the request couldn't be read"
    assert answer_of(dropbox, "BBBBBBBB-arriving") is None
    assert indexer.next_plot_look - time.monotonic() <= 2  # looked at again in a couple of seconds
    assert plot_log() == []


def test_asking_twice_plots_once(dropbox, tmp_path, make_indexer, plot_log):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    entry = entries(dropbox)[("E-202.dwg", "Layout1")]
    first, second = ask(dropbox, entry), ask(dropbox, entry)
    answer_now(indexer)
    a, b = answer_of(dropbox, first), answer_of(dropbox, second)
    assert a["state"] == b["state"] == "done" and a["pdf"] == b["pdf"]
    assert [r["mode"] for r in plot_log()] == ["saved", "fallback"]  # one plot, not two
    third = ask(dropbox, entry)  # and again once plotted
    answer_now(indexer)
    assert answer_of(dropbox, third)["pdf"] == a["pdf"]
    assert len([r for r in plot_log() if r["mode"] == "saved"]) == budget("plot_console_runs_asked_twice") == 1


def test_one_plot_writes_seven_files_to_dropbox(dropbox, tmp_path, make_indexer, plot_log):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    ask(dropbox, entries(dropbox)[("E-202.dwg", "Layout1")])
    indexer.writer.counts.files = 0
    indexer.counters.plot_answers = indexer.counters.plots_made = 0
    acknowledger = pr.Acknowledger(indexer.plot_folder)
    acknowledger.look()  # "queued", as the watcher's acknowledger writes it
    answer_now(indexer)  # "plotting", then "done"
    written = (indexer.writer.counts.files + acknowledger.acknowledged + indexer.counters.plot_answers
               + indexer.counters.plots_made)
    assert (indexer.writer.counts.files, acknowledger.acknowledged, indexer.counters.plot_answers,
            indexer.counters.plots_made) == (3, 1, 2, 1)
    assert written == budget("dropbox_files_written_one_plot") == 7


def test_a_replot_of_a_changed_dwg_takes_the_pdfs_place_and_keeps_the_older_in_other_pdfs(dropbox, tmp_path,
                                                                                         make_indexer, plot_log):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    n = ask(dropbox, entries(dropbox)[("E-202.dwg", "Layout1")])
    answer_now(indexer)
    first = answer_of(dropbox, n)["pdf"]
    dwg = dropbox / PLANT / "CAD" / "E-202.dwg"
    make_dxf(dwg, [("Layout1", {"DWG_NO": "E-202", "TITLE": "Boiler room lighting plan", "REV": "1"})])
    touch(dwg, 1_800_000_000)
    indexer.scan()
    entry = entries(dropbox)[("E-202.dwg", "Layout1")]
    assert entry["pdf"]["path"] == first  # the older plot still shows until the new one is made
    n2 = ask(dropbox, entry)
    answer_now(indexer)
    second = answer_of(dropbox, n2)["pdf"]
    assert second != first and "2027-01-15 080000" in second
    entry = entries(dropbox)[("E-202.dwg", "Layout1")]
    assert entry["pdf"]["path"] == second and entry["otherPdfs"] == [first] and entry["pairedBy"] == "plotted"
    assert (dropbox / first.lstrip("/")).exists()  # the older plot is kept, never deleted


def test_a_plot_deleted_from_dropbox_leaves_the_index(dropbox, tmp_path, make_indexer, plot_log):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    name = ask(dropbox, entries(dropbox)[("E-202.dwg", "Layout1")])
    answer_now(indexer)
    (dropbox / answer_of(dropbox, name)["pdf"].lstrip("/")).unlink()
    indexer.scan()
    assert entries(dropbox)[("E-202.dwg", "Layout1")]["pdf"] is None


# --- Jumping the scan's queue ------------------------------------------------------------------------------------

def test_a_request_goes_ahead_of_the_scans_reading_queue(dropbox, tmp_path, make_indexer, plot_log):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    entry = entries(dropbox)[("E-202.dwg", "Layout1")]
    for i in range(20):  # a long scan: twenty new DWGs for AutoCAD to read
        make_dxf(dropbox / PLANT / "CAD" / "New" / f"N-{i:02}.dwg", [("Layout1", {"DWG_NO": f"N-{i:02}"})])
    order = []
    reader = indexer.dwg_reader
    real = reader.read

    def read(path, work=None):
        order.append(path.name)
        if len(order) == 2:  # the Duo asks while the scan is part way
            order.append(f"asked {ask(dropbox, entry)}")
            indexer.plot_wanted.set()
        return real(path, work)

    reader.read = read
    real_answer = indexer.plot_folder.answer

    def answered(answer):
        order.append(f"answered {answer.state}")
        real_answer(answer)

    indexer.plot_folder.answer = answered
    indexer.scan()
    asked = next(i for i, x in enumerate(order) if x.startswith("asked"))
    assert order[asked + 1:asked + 3] == ["answered plotting", "answered done"]  # before the next DWG is read
    assert len([x for x in order if x.endswith(".dwg")]) == 20


def test_a_request_is_answered_during_a_first_scans_listing(dropbox, tmp_path, make_indexer, plot_log):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    entry = entries(dropbox)[("E-202.dwg", "Layout1")]
    pdf = make_pdf(tmp_path / "one.pdf").read_bytes()
    for i in range(300):
        p = dropbox / "Projects" / "Made-up Dam" / "PDF" / f"D-{i:03}.pdf"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(pdf)
    name = ask(dropbox, entry)
    indexer.plot_wanted.clear()
    indexer.next_plot_look = time.monotonic() + 3600
    read_before = []
    real = indexer.plot_folder.answer

    def answered(answer):
        read_before.append(indexer.counters.pdfs_read)
        real(answer)

    indexer.plot_folder.answer = answered
    listed = {"n": 0}
    attributes = indexer.attributes

    def counting(path, st):
        listed["n"] += 1
        if listed["n"] == 10:
            indexer.plot_wanted.set()  # the watcher saw the request arrive
        return attributes(path, st)

    indexer.attributes = counting
    indexer.counters.pdfs_read = 0
    indexer.scan()
    assert answer_of(dropbox, name)["state"] == "done"
    assert read_before[-1] == 1  # answered while listing: only the plot's own PDF read, none of the 300 yet


# --- Online-only DWGs ------------------------------------------------------------------------------------------

def test_an_online_only_dwg_is_plotted_from_a_copy_on_the_scratch_drive(dropbox, tmp_path, make_indexer, plot_log):
    from test_online_only import scratch_files, set_up

    server, _, _, scratch, downloader, online = set_up(dropbox, tmp_path)
    online.names = {"E-202.dwg"}
    indexer = make_indexer(attributes=online, downloader=downloader, plotter=plotter(tmp_path))
    indexer.scan()
    server.downloads.clear()
    name = ask(dropbox, entries(dropbox)[("E-202.dwg", "Layout1")])
    answer_now(indexer)
    assert answer_of(dropbox, name)["state"] == "done"
    assert server.downloads == [f"/{PLANT}/CAD/E-202.dwg"]
    for run in plot_log():  # AutoCAD worked in the scratch drive's work folder, never on C: or in Dropbox
        assert Path(run["drawing"]).is_relative_to(downloader.work)
        assert run["folder"] == (dropbox / PLANT / "CAD").as_posix()  # references found from its Dropbox folder
    assert scratch_files(scratch) == []


def test_an_online_only_dwg_with_no_drive_is_answered_failed(dropbox, tmp_path, make_indexer, plot_log):
    from test_online_only import set_up

    _, _, drive, _, downloader, online = set_up(dropbox, tmp_path)
    online.names = {"E-202.dwg"}
    indexer = make_indexer(attributes=online, downloader=downloader, plotter=plotter(tmp_path))
    indexer.scan()
    drive.present = False
    name = ask(dropbox, entries(dropbox)[("E-202.dwg", "Layout1")])
    answer_now(indexer)
    answer = answer_of(dropbox, name)
    assert answer["state"] == "failed" and answer["reason"].startswith("the DWG is online-only, and the laptop can't")
    assert "is not there" in answer["reason"] and plot_log() == []


# --- Cleanup and the check-in --------------------------------------------------------------------------------------

def test_cleanup_never_removes_a_request_and_removes_an_answer_only_after_its_request(tmp_path):
    folder = tmp_path / "Dropbox" / "Vellum" / "Plots"
    clock = FakeClock(time.time())
    plots = PlotFolder(folder, clock=clock)
    requests = folder / "requests"
    requests.mkdir(parents=True)
    week = time.time() - 7 * 86400
    names = {
        "unanswered": "AAAAAAAA-1", "answered": "BBBBBBBB-2", "read-by-duo": "CCCCCCCC-3", "just-read": "DDDDDDDD-4",
    }
    for key in ("unanswered", "answered"):
        (requests / f"{names[key]}.json").write_text(json.dumps(GOOD))
    for key in ("answered", "read-by-duo", "just-read"):
        plots.answer(pr.Answer(names[key], "done", pdf="/Vellum/Plots/x.pdf"))
    for p in requests.iterdir():
        if "just-read" not in p.name and names["just-read"] not in p.name:
            os.utime(p, (week, week))
    everything = sorted(p.name for p in requests.iterdir())
    assert plots.clean() == 0  # a week-old answer whose request has only now been seen gone stays
    clock.now += 59 * 60
    assert plots.clean() == 0 and sorted(p.name for p in requests.iterdir()) == everything
    clock.now += 2 * 60  # an hour after its request was first seen gone
    assert plots.clean() == 2
    left = sorted(p.name for p in requests.iterdir())
    assert left == sorted([f"{names['unanswered']}.json", f"{names['answered']}.json",
                           f"{names['answered']}.answer.json"])
    assert [n for n, _ in plots.pending()] == [names["unanswered"]]


class FakeClock:
    def __init__(self, now: float):
        self.now = now

    def __call__(self) -> float:
        return self.now


def test_an_hour_counts_from_when_the_request_went_not_from_the_answers_age(tmp_path):
    folder = tmp_path / "Dropbox" / "Vellum" / "Plots"
    clock = FakeClock(time.time())
    plots = PlotFolder(folder, clock=clock)
    (folder / "requests").mkdir(parents=True)
    request = folder / "requests" / "EEEEEEEE-5.json"
    request.write_text(json.dumps(GOOD))
    plots.answer(pr.Answer("EEEEEEEE-5", "done", pdf="/Vellum/Plots/x.pdf"))
    day = time.time() - 86400
    os.utime(folder / "requests" / "EEEEEEEE-5.answer.json", (day, day))  # a day-old answer
    assert plots.clean() == 0  # its request still there
    clock.now += 3600 * 5
    request.unlink()  # the Duo has just read the answer and deleted its request
    assert plots.clean() == 0
    clock.now += 3599
    assert plots.clean() == 0 and (folder / "requests" / "EEEEEEEE-5.answer.json").exists()
    clock.now += 2
    assert plots.clean() == 1 and not (folder / "requests" / "EEEEEEEE-5.answer.json").exists()


def test_the_check_in_is_written_atomically_and_kept_fresh(tmp_path):
    folder = tmp_path / "Dropbox" / "Vellum" / "Plots"
    check_in = CheckIn(PlotFolder(folder), "1.1.0", every=0.2)
    check_in.start()
    try:
        assert (folder / "laptop.json").exists()
        deadline = time.monotonic() + 10
        while check_in.writes < 4 and time.monotonic() < deadline:
            time.sleep(0.05)
    finally:
        check_in.close()
    assert check_in.writes >= 4
    body = json.loads((folder / "laptop.json").read_text())
    assert set(body) == {"format", "seen", "indexer", "every", "staleAfter"}  # a time and a version, nothing else
    assert body["format"] == 1 and body["indexer"] == "1.1.0" and body["every"] == 120 and body["staleAfter"] == 300
    assert 3600 // pr.CHECK_IN_SECONDS == budget("check_in_writes_per_hour") == 30
    seen = calendar.timegm(time.strptime(body["seen"], "%Y-%m-%dT%H:%M:%SZ"))
    assert abs(seen - time.time()) < 5
    assert sorted(p.name for p in folder.iterdir()) == ["laptop.json"]  # no temp left beside it


# --- Nothing outside Dropbox/Vellum ---------------------------------------------------------------------------

def snapshot(root: Path) -> dict[str, bytes]:
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob("*") if p.is_file()}


def test_nothing_is_written_outside_dropbox_vellum_and_no_project_file_changes(dropbox, tmp_path, make_indexer,
                                                                                plot_log):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    entry = entries(dropbox)[("E-202.dwg", "Layout1")]
    before = snapshot(tmp_path)
    good = ask(dropbox, entry)
    hostile = [
        ask(dropbox, entry, path="/../../outside/E-202.dwg"),
        ask(dropbox, entry, path="/Projects/Made-up Plant Upgrade/CAD/E-202.dwg/../../../../x.dwg"),
        ask(dropbox, entry, layout='Layout1" (command "_.QSAVE") "'),
    ]
    answer_now(indexer)
    assert answer_of(dropbox, good)["state"] == "done"
    assert all(answer_of(dropbox, h)["state"] == "failed" for h in hostile)
    after = snapshot(tmp_path)
    changed = {k for k in after if before.get(k) != after[k]} | {k for k in before if k not in after}
    outside = [k for k in changed
               if not k.startswith("Dropbox/Vellum/") and not k.startswith("home/") and k != "fake-plot-log.jsonl"]
    assert outside == []
    assert all(k.startswith(("Dropbox/Vellum/Plots/", "Dropbox/Vellum/Index/")) for k in changed
               if k.startswith("Dropbox/"))
    assert [r["layout"] for r in plot_log()] == ["Layout1", "Layout1"]  # the index's layout, never the request's


# --- The watcher -----------------------------------------------------------------------------------------------

def test_the_watcher_answers_a_request_within_seconds_and_checks_in(dropbox, tmp_path, make_indexer, plot_log,
                                                                    caplog):
    import logging

    from vellum_indexer.watch import watch

    caplog.set_level(logging.DEBUG, logger="vellum_indexer")

    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    stop = threading.Event()
    thread = threading.Thread(target=watch, args=(indexer, 0.5, 10, 24, stop), kwargs={"check_in_seconds": 0.5},
                              daemon=True)
    thread.start()
    try:
        deadline = time.monotonic() + 15
        while not (dropbox / "Vellum" / "Index" / "index.json").exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert (dropbox / "Vellum" / "Plots" / "laptop.json").exists()
        assert requests_folder(dropbox).is_dir()  # made at start, so a request lands in a watched folder
        indexer.next_plot_look = time.monotonic() + 3600  # not the minute's look: the notice or the 2 s listing
        asked = time.monotonic()
        name = ask(dropbox, entries(dropbox)[("E-202.dwg", "Layout1")])
        while (answer_of(dropbox, name) or {}).get("state") != "done" and time.monotonic() - asked < 20:
            time.sleep(0.05)
        took = time.monotonic() - asked
        assert (answer_of(dropbox, name) or {}).get("state") == "done", (
            f"no answer after {took:.1f} s; due {indexer.plots_due()}, files "
            f"{sorted(p.name for p in requests_folder(dropbox).iterdir())}")
        assert took < 15, took
        writes = indexer.check_in.writes
        time.sleep(1.2)
        assert indexer.check_in.writes > writes
    finally:
        stop.set()
        thread.join(10)


def test_the_watchers_events_wake_the_indexer_for_requests_only(dropbox):
    from vellum_indexer.files import SkipRules
    from vellum_indexer.watch import Debouncer, DropboxEvents

    woken = []
    d = Debouncer()
    events = DropboxEvents(dropbox, SkipRules(), d, on_plot_request=lambda: woken.append(1))
    requests = requests_folder(dropbox)
    events.handle("created", str(requests / "6F1C2B9A-0D3E-4A5B-8C7D-1E2F3A4B5C6D.json"), None, False)
    events.handle("moved", str(dropbox / ".dropbox.cache" / "x"), str(requests / "AAAAAAAA-0001.json"), False)
    events.handle("created", str(requests), None, True)  # the folder itself appearing
    assert len(woken) == 3
    for quiet in [("modified", requests / "AAAAAAAA-0001.answer.json", False),  # the laptop's own answer
                  ("created", requests / "~$AAAAAAAA-0001.answer.json.12.tmp", False),
                  ("deleted", requests / "AAAAAAAA-0001.json", False),  # the Duo tidying up
                  ("modified", dropbox / "Vellum" / "Plots" / "laptop.json", False)]:
        events.handle(quiet[0], str(quiet[1]), None, quiet[2])
    assert len(woken) == 3 and d.take()[0] == set()  # and no request is sent to the drawing reader


# --- Review fixes (#67 round 2) ----------------------------------------------------------------------------------

def test_relative_references_are_made_absolute_against_the_originals_folder_and_missing_ones_reach_the_answer(
        dropbox, tmp_path, make_indexer, plot_log):
    import ezdxf

    cad = dropbox / PLANT / "CAD"
    dwg = make_dxf(cad / "E-501.dwg", [("Layout1", {"DWG_NO": "E-501"})], setups={"Layout1": ARCH_D})
    doc = ezdxf.readfile(dwg)
    doc.add_xref_def("..\\Xrefs\\base.dwg", "BASE")  # relative, there
    doc.add_image_def("..\\Images\\photo.png", (100, 100))  # relative, missing
    doc.add_underlay_def("vendor.pdf", "pdf", "1")  # relative, in the same folder, there
    doc.saveas(dwg)
    make_dxf(dropbox / PLANT / "Xrefs" / "base.dwg", [("Layout1", {"NOTE": "made-up base"})])
    make_pdf(cad / "vendor.pdf")
    before = sorted(p.name for p in cad.iterdir())
    original = dwg.read_bytes()
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    name = ask(dropbox, entries(dropbox)[("E-501.dwg", "Layout1")])
    answer_now(indexer)
    answer = answer_of(dropbox, name)
    assert answer["state"] == "done" and answer["missingReferences"] == 1
    assert answer["warning"] == "1 reference couldn't be found, so the PDF is missing it"
    run = plot_log()[0]
    assert run["folder"] == cad.as_posix()  # the original's folder, not the job folder the copy is in
    assert Path(run["drawing"]).parent != cad
    assert sorted(p.name for p in cad.iterdir()) == before and dwg.read_bytes() == original  # original untouched


def test_the_plot_report_counts_references():
    from vellum_indexer.plot import Reference, parse_info

    text = ("SETUP\tLayout1\tDWG To PDF.pc3\tARCH D\t914.40\t609.60\t0\nREF\txref\tC:/P/Xrefs/base.dwg\t1\n"
            "REF\timage\tC:/P/Images/photo.png\t0\nPLOTTED\nEND\n")
    setup, outcome, refs = parse_info(text)
    assert outcome == "PLOTTED" and setup.layout == "Layout1"
    assert refs == [Reference("xref", "C:/P/Xrefs/base.dwg", True), Reference("image", "C:/P/Images/photo.png", False)]
    assert pr.missing_warning(0) is None
    assert pr.missing_warning(2) == "2 references couldn't be found, so the PDF is missing them"


def test_a_request_is_answered_queued_while_a_long_read_is_still_running(dropbox, tmp_path, make_indexer, plot_log):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    entry = entries(dropbox)[("E-202.dwg", "Layout1")]
    make_dxf(dropbox / PLANT / "CAD" / "Slow.dwg", [("Layout1", {"DWG_NO": "S-1"})])
    reading, release = threading.Event(), threading.Event()
    real = indexer.dwg_reader.read

    def stalled(path, work=None):
        if path.name == "Slow.dwg":
            reading.set()
            release.wait(30)  # AutoCAD stuck on one drawing
        return real(path, work)

    indexer.dwg_reader.read = stalled
    acknowledger = pr.Acknowledger(indexer.plot_folder, on_new=indexer.plot_wanted.set, every=0.1)
    acknowledger.start()
    scan = threading.Thread(target=indexer.scan, daemon=True)
    try:
        scan.start()
        assert reading.wait(15)
        name = ask(dropbox, entry)
        acknowledger.wake()
        deadline = time.monotonic() + 10
        while answer_of(dropbox, name) is None and time.monotonic() < deadline:
            time.sleep(0.02)
        assert answer_of(dropbox, name)["state"] == "queued" and answer_of(dropbox, name)["id"] == entry["id"]
        assert not release.is_set() and plot_log() == []  # the read is still running; nothing plotted yet
        release.set()
        scan.join(30)
        assert answer_of(dropbox, name)["state"] == "done"  # plotted as soon as the read ended
    finally:
        release.set()
        acknowledger.close()
        scan.join(30)


def test_the_acknowledger_refuses_garbage_and_never_overwrites_a_later_answer(tmp_path):
    folder = tmp_path / "Dropbox" / "Vellum" / "Plots"
    plots = PlotFolder(folder)
    (folder / "requests").mkdir(parents=True)
    (folder / "requests" / "AAAAAAAA-1.json").write_text(json.dumps(GOOD))
    (folder / "requests" / "BBBBBBBB-2.json").write_text(json.dumps({**GOOD, "format": 9}))
    (folder / "requests" / "CCCCCCCC-3.json").write_text(json.dumps(GOOD))
    plots.answer(pr.Answer("CCCCCCCC-3", "plotting"))
    woken = []
    acknowledger = pr.Acknowledger(plots, on_new=lambda: woken.append(1))
    assert acknowledger.look() == 2
    assert plots.answer_state("AAAAAAAA-1") == "queued" and plots.answer_state("BBBBBBBB-2") == "failed"
    assert plots.answer_state("CCCCCCCC-3") == "plotting" and woken == [1]
    assert not plots.answer_if_none(pr.Answer("AAAAAAAA-1", "queued"))  # never over an answer already there
    assert acknowledger.look() == 0


def test_a_plot_backlog_takes_one_plot_a_turn_with_the_scan_between(dropbox, tmp_path, make_indexer, plot_log):
    small_tree(dropbox)
    for n in ("E-601", "E-602", "E-603"):
        make_dxf(dropbox / PLANT / "CAD" / f"{n}.dwg", [("Layout1", {"DWG_NO": n})], setups={"Layout1": ARCH_D})
    indexer = make_indexer(plotter=plotter(tmp_path, "hang", timeout=1))  # every console times out
    indexer.scan()
    listed = entries(dropbox)
    names = [ask(dropbox, listed[(f"{n}.dwg", "Layout1")]) for n in ("E-601", "E-602", "E-603")]
    for n, name in enumerate(names):  # oldest first
        t = time.time() - 100 + n
        os.utime(requests_folder(dropbox) / f"{name}.json", (t, t))
    indexer.plot_wanted.set()
    indexer.answer_plot_requests()
    assert [answer_of(dropbox, n) and answer_of(dropbox, n)["state"] for n in names] == ["failed", None, None]
    assert len(plot_log()) == 1 and indexer.plot_wanted.is_set()  # the rest wait for the next turn

    # in a scan, a file is read between plots
    for i in range(3):
        make_dxf(dropbox / PLANT / "CAD" / "New" / f"N-{i}.dwg", [("Layout1", {"DWG_NO": f"N-{i}"})])
    order = []
    real = indexer.dwg_reader.read

    def read(path, work=None):
        order.append("read")
        return real(path, work)

    indexer.dwg_reader.read = read
    real_answer = indexer.plot_folder.answer

    def answered(answer):
        if answer.state == "failed":
            order.append("plot")
        real_answer(answer)

    indexer.plot_folder.answer = answered
    indexer.scan()
    assert order[:4] == ["plot", "read", "plot", "read"]
    assert all(answer_of(dropbox, n)["state"] == "failed" for n in names)


@pytest.mark.parametrize("raw, reason", [
    ('"/Projects/\\ud800.dwg"', "isn't a Dropbox path"),  # a lone surrogate, escaped in JSON
    ('"/Projects/E-202\\u0000.dwg"', "isn't a Dropbox path"),  # a NUL
    ('"/' + "a" * 10000 + '.dwg"', "too big to be a plot request"),  # a 10,000-character path
])
def test_a_malformed_string_is_refused_and_never_stops_the_indexer(dropbox, tmp_path, make_indexer, plot_log, raw,
                                                                   reason):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    entry = entries(dropbox)[("E-202.dwg", "Layout1")]
    folder = requests_folder(dropbox)
    folder.mkdir(parents=True, exist_ok=True)
    body = ('{"format": 1, "id": "' + entry["id"] + '", "path": ' + raw
            + ', "layout": "Layout1", "asked": "2026-11-07T12:00:00Z"}')
    (folder / "AAAAAAAA-bad.json").write_text(body, encoding="utf-8")
    old = time.time() - 100
    os.utime(folder / "AAAAAAAA-bad.json", (old, old))
    good = ask(dropbox, entry)
    answer_now(indexer)
    bad = answer_of(dropbox, "AAAAAAAA-bad")
    assert bad["state"] == "failed" and reason in bad["reason"]
    assert answer_of(dropbox, good)["state"] == "done"  # the next request is still answered
    with pytest.raises(Refused, match=reason):
        decode("abcdefgh", body.encode("utf-8"), age_seconds=60)


def test_a_path_over_1024_characters_is_refused_even_in_a_small_request():
    with pytest.raises(Refused, match="isn't a Dropbox path"):
        decode("abcdefgh", json.dumps({**GOOD, "path": "/" + "a" * 2000 + ".dwg"}).encode(), age_seconds=60)


def test_each_string_in_a_request_is_checked():
    for field, value in (("layout", "Layout\ud8001"), ("layout", "Lay\x00out"), ("layout", "L" * 300),
                         ("asked", "2026-11-07T12:00:00Z\x07"), ("id", "dd0bdad0ab9b908\x00")):
        with pytest.raises(Refused):
            decode("abcdefgh", json.dumps({**GOOD, field: value}).encode(), age_seconds=60)


def test_an_unexpected_error_in_one_request_is_answered_failed_and_the_next_is_still_plotted(
        dropbox, tmp_path, make_indexer, plot_log, monkeypatch):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    entry = entries(dropbox)[("E-202.dwg", "Layout1")]
    first = ask(dropbox, entry)
    t = time.time() - 100
    os.utime(requests_folder(dropbox) / f"{first}.json", (t, t))
    second = ask(dropbox, entry)
    real = indexer._entry_of
    calls = []

    def flaky(request):
        calls.append(request.name)
        if len(calls) == 1:
            raise RuntimeError("made-up surprise")
        return real(request)

    monkeypatch.setattr(indexer, "_entry_of", flaky)
    answer_now(indexer)
    assert answer_of(dropbox, first)["state"] == "failed"
    assert answer_of(dropbox, first)["reason"] == "the laptop couldn't handle this request (RuntimeError)"
    assert answer_of(dropbox, second)["state"] == "done"


def test_a_replot_within_the_same_second_keeps_the_older_plot(dropbox, tmp_path, make_indexer, plot_log):
    small_tree(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    dwg = dropbox / PLANT / "CAD" / "E-202.dwg"
    second = 1_800_000_000 * 10**9
    os.utime(dwg, ns=(second, second + 100_000_000))
    indexer.scan()
    n1 = ask(dropbox, entries(dropbox)[("E-202.dwg", "Layout1")])
    answer_now(indexer)
    first = answer_of(dropbox, n1)["pdf"]
    make_dxf(dwg, [("Layout1", {"DWG_NO": "E-202", "TITLE": "Boiler room lighting plan", "REV": "2"})])
    os.utime(dwg, ns=(second, second + 700_000_000))  # saved again in the same second
    indexer.scan()
    n2 = ask(dropbox, entries(dropbox)[("E-202.dwg", "Layout1")])
    answer_now(indexer)
    newer = answer_of(dropbox, n2)["pdf"]
    assert newer != first and newer.rsplit(" - ", 2)[1] == first.rsplit(" - ", 2)[1]  # same second shown
    assert (dropbox / first.lstrip("/")).exists() and (dropbox / newer.lstrip("/")).exists()
    entry = entries(dropbox)[("E-202.dwg", "Layout1")]
    assert entry["pdf"]["path"] == newer and entry["otherPdfs"] == [first]


class LateReader:
    """Reads no title blocks until ``ready``, as a DWG not read yet (AutoCAD missing, or online-only)."""

    def __init__(self):
        from makers import DxfReader

        self.inner = DxfReader()
        self.ready = False
        self.id = "late-0"

    def read(self, path, work=None):
        return self.inner.read(path, work) if self.ready else []

    def come_ready(self):
        self.ready, self.id = True, "late-1"


@pytest.mark.parametrize("active, layouts, kept_on", [
    ("Layout1", ["Layout1"], "Layout1"),  # the DWG's one layout
    ("Layout2", ["Layout1", "Layout2"], "Layout2"),  # the layout AutoCAD plotted
])
def test_a_plot_of_a_dwg_with_no_layout_yet_stays_once_its_layouts_are_known(dropbox, tmp_path, make_indexer,
                                                                            plot_log, active, layouts, kept_on):
    import ezdxf

    dwg = make_dxf(dropbox / PLANT / "CAD" / "E-701.dwg",
                   [(name, {"DWG_NO": f"E-701-{i}", "TITLE": f"Made-up {name}"}) for i, name in enumerate(layouts)],
                   setups={name: ARCH_D for name in layouts})
    doc = ezdxf.readfile(dwg)
    doc.layouts.set_active_layout(active)
    doc.saveas(dwg)
    reader = LateReader()
    indexer = make_indexer(plotter=plotter(tmp_path), dwg_reader=reader)
    indexer.scan()
    entry = entries(dropbox)[("E-701.dwg", None)]  # title blocks not read: one entry, no layout
    name = ask(dropbox, entry)
    answer_now(indexer)
    pdf = answer_of(dropbox, name)["pdf"]
    assert plot_log()[0]["layout"] == ""  # the layout it was saved on
    reader.come_ready()
    indexer.scan()
    listed = entries(dropbox)
    assert ("E-701.dwg", None) not in listed
    assert listed[("E-701.dwg", kept_on)]["pdf"]["path"] == pdf
    assert listed[("E-701.dwg", kept_on)]["pairedBy"] == "plotted"
    for other in set(layouts) - {kept_on}:
        assert listed[("E-701.dwg", other)]["pdf"] is None


# --- The Model tab and answers out of step (#87) -----------------------------------------------------------------

MODEL_ANSWERS = ["_.-PLOT", "_Y", "Model", "DWG To PDF.pc3", "ANSI full bleed A (8.50 x 11.00 Inches)", "_I", "_L",
                 "_N", "_E", "_F", "", "_Y", "", "_Y", "_A", "<out>", "_N", "_Y"]
# detailed, layout, device, paper, units, orientation, upside down, area, scale (Fit, #92), offset, plot styles, style
# table, lineweights, then the shade plot setting on the Model tab
FITTED_REASON = ("the Model tab has no page setup that plots to PDF, so its extents were plotted with DWG To PDF to "
                 "fit the page, not to scale")


def model_dwg(dropbox: Path) -> Path:
    """A made-up DWG saved on the Model tab, its title block in model space, with no PDF plotter saved: ANSI A."""
    dwg = make_dxf(dropbox / PLANT / "CAD" / "M-101.dwg", [("Model", {"DWG_NO": "M-101", "TITLE": "Made-up model"})],
                   setups={"Model": {"device": "None", "media": "ANSI_A_(11.00_x_8.50_Inches)", "size": (279.4, 215.9)}})
    return dwg


def test_a_model_tab_dwg_falls_back_to_its_extents_fitted_with_the_model_tabs_answers(dropbox, tmp_path, make_indexer,
                                                                                         plot_log):
    model_dwg(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path, timeout=10))
    indexer.scan()
    name = ask(dropbox, entries(dropbox)[("M-101.dwg", "Model")])
    started = time.monotonic()
    answer_now(indexer)
    assert time.monotonic() - started < 8
    answer = answer_of(dropbox, name)
    assert (answer["state"], answer["pageSetup"]) == ("done", "fallback")
    assert answer["reason"] == FITTED_REASON
    assert answer["fitted"] is True
    listed = entries(dropbox)[("M-101.dwg", "Model")]
    assert listed["pdf"]["path"] == answer["pdf"] and listed["pdf"]["fitted"] is True
    runs = plot_log()
    assert [r["mode"] for r in runs] == ["saved", "model"]
    out = runs[1]["answers"][14]
    assert runs[1]["answers"] == [a if a != "<out>" else out for a in MODEL_ANSWERS[1:]]
    assert out.endswith("/model.pdf")
    # asked again, unchanged: the same PDF, and the same reason
    again = ask(dropbox, entries(dropbox)[("M-101.dwg", "Model")])
    answer_now(indexer)
    assert answer_of(dropbox, again)["reason"] == answer["reason"] and len(plot_log()) == 2
    assert answer_of(dropbox, again)["fitted"] is True and answer_of(dropbox, again)["pdf"] == answer["pdf"]


def test_a_model_tab_plot_made_at_1_1_before_92_is_plotted_again_fitted_and_kept_as_an_older_plot(
        dropbox, tmp_path, make_indexer, plot_log):
    from vellum_indexer import files
    from vellum_indexer import plot as plot_module
    from vellum_indexer.state import Plot

    dwg = model_dwg(dropbox)
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    entry = entries(dropbox)[("M-101.dwg", "Model")]
    # the plot 1.1.1 made (#90): the Model tab's extents at 1:1, named as it named it, with no fitted mark
    st = dwg.stat()
    old = plot_name("Made-up Plant Upgrade", entry["dwg"]["path"], "Model", st.st_mtime_ns,
                    plot_module.file_version(dwg))
    old_file = files.local_path(dropbox, old)
    make_pdf(old_file, [(72, 72, 12, "Made-up 1:1 plot of Model")], inches=(11, 8.5))
    facts = {**indexer._read("pdf", old_file), "pageSetup": "fallback", "plottedLayout": "Model", "references": 0,
             "missingReferences": 0}
    pst = old_file.stat()
    sheet = f"{files.key(entry['dwg']['path'])}#model"
    indexer.state.put_plot(Plot(sheet, st.st_size, st.st_mtime_ns, old, pst.st_size, pst.st_mtime_ns - 10**9, facts))
    indexer.publish()
    assert entries(dropbox)[("M-101.dwg", "Model")]["pdf"]["path"] == old
    assert "fitted" not in entries(dropbox)[("M-101.dwg", "Model")]["pdf"]

    name = ask(dropbox, entry)
    answer_now(indexer)
    answer = answer_of(dropbox, name)
    assert [r["mode"] for r in plot_log()] == ["saved", "model"]  # plotted again, not the 1:1 plot handed back
    assert (answer["state"], answer["fitted"], answer["reason"]) == ("done", True, FITTED_REASON)
    assert answer["pdf"] != old and answer["pdf"].startswith("/Vellum/Plots/Made-up Plant Upgrade/M-101 - Model - ")
    assert old_file.read_bytes().startswith(b"%PDF")  # the old plot is not overwritten
    listed = entries(dropbox)[("M-101.dwg", "Model")]
    assert listed["pdf"]["path"] == answer["pdf"] and listed["pdf"]["fitted"] is True
    assert listed["otherPdfs"] == [old]
    # asked again: the fitted plot, not plotted a third time
    again = ask(dropbox, entry)
    answer_now(indexer)
    assert answer_of(dropbox, again)["pdf"] == answer["pdf"] and len(plot_log()) == 2


def test_a_fitted_plot_never_takes_another_plots_name():
    t = 1_790_000_000 * 10**9
    args = ("Made-up Plant Upgrade", "/Projects/Made-up Plant Upgrade/CAD/M-101.dwg", "Model", t, "abc")
    assert plot_name(*args) != plot_name(*args, mode="fit")
    assert plot_name(*args, mode="fit").rsplit(" - ", 1)[0] == plot_name(*args).rsplit(" - ", 1)[0]
    assert plot_name(*args, mode="") == plot_name(*args)  # paper layouts keep the names they had


def test_a_paper_layout_falls_back_with_the_layouts_answers_unchanged(dropbox, tmp_path, make_indexer, plot_log):
    small_tree(dropbox)  # E-202's Layout1: no plotter saved, A3
    indexer = make_indexer(plotter=plotter(tmp_path))
    indexer.scan()
    name = ask(dropbox, entries(dropbox)[("E-202.dwg", "Layout1")])
    answer_now(indexer)
    answer = answer_of(dropbox, name)
    assert answer["state"] == "done" and answer["reason"] == ("the layout has no page setup that plots to PDF, so it "
                                                              "was plotted with DWG To PDF at its paper size")
    run = plot_log()[1]
    assert run["mode"] == "fallback"
    assert run["answers"][:13] == ["_Y", "Layout1", "DWG To PDF.pc3", "ISO full bleed A3 (297.00 x 420.00 MM)", "_M",
                                   "_L", "_N", "_L", "1:1", "", "_Y", "", "_Y"]
    assert run["answers"][13:16] == ["_N", "_N", "_N"]  # scale lineweights, paper space first, hide paperspace
    assert run["answers"][16].endswith("/fallback.pdf") and run["answers"][17:] == ["_N", "_Y"]
    assert answer["fitted"] is False and "fitted" not in entries(dropbox)[("E-202.dwg", "Layout1")]["pdf"]


def test_answers_out_of_step_fail_within_seconds_with_a_plain_reason(dropbox, tmp_path, make_indexer, plot_log,
                                                                       monkeypatch):
    from vellum_indexer import plot as plot_module

    model_dwg(dropbox)
    # the Model tab given the paper layout's answers, as the indexer did before #87
    monkeypatch.setattr(plot_module.AccoreconsolePlotter, "model_mode", "fallback")
    indexer = make_indexer(plotter=plotter(tmp_path, timeout=30))
    indexer.scan()
    name = ask(dropbox, entries(dropbox)[("M-101.dwg", "Model")])
    started = time.monotonic()
    answer_now(indexer)
    assert time.monotonic() - started < 15
    answer = answer_of(dropbox, name)
    assert (answer["state"], answer["pdf"]) == ("failed", None)
    assert answer["reason"] == "AutoCAD stopped at a question the laptop didn't expect while plotting"
    assert list((tmp_path / "home" / "work").iterdir()) == []


def test_a_console_that_writes_end_and_does_not_quit_is_stopped(tmp_path):
    dwg = make_dxf(tmp_path / "E-301.dwg", [("Layout1", {"DWG_NO": "E-301"})], setups={"Layout1": ARCH_D})
    started = time.monotonic()
    result = plotter(tmp_path, "linger", timeout=30).plot(dwg, "Layout1")
    assert time.monotonic() - started < 15
    assert result.page_setup == "saved" and result.pdf.startswith(b"%PDF")


def test_the_lisp_catches_a_cancelled_plot_and_reports_failed():
    from fake_plot_console import CALLS_COMMAND, forms_starting
    from vellum_indexer.plot import parse_info

    script = plot_script("Model", Path("C:/w/model.pdf"), Path("C:/w/model.txt"), "model", "ANSI A", "Inches")
    assert "*error*" in script and "FAILED" in script
    assert '"_E" "1:1" "" "_Y" "" "_Y"\n' not in script and '"_A" out "_N" "_Y"' in script
    assert '"_E" "_F" "" "_Y" "" "_Y" "_A" out "_N" "_Y"' in script and '"_L" "1:1" "" "_Y" "" "_Y" "_N"' in script
    # AutoCAD refuses a command inside vl-catch-all-apply or *error* ("bad order function: COMMAND", #87)
    for form in forms_starting(script, "(vl-catch-all-apply") + forms_starting(script, "(setq *error*"):
        assert not CALLS_COMMAND.search(form), form
    _, outcome, _ = parse_info("SETUP\tModel\tNone\tANSI A\t279.40\t215.90\t0\nFAILED\tFunction cancelled\nEND\n")
    assert outcome == "FAILED"


def fake_run(tmp_path: Path, script: str, layout: str = "Layout1") -> tuple[str, str]:
    """The stand-in console run once on a made-up DWG with ``script``, not left to sit: its report and its output."""
    import subprocess

    dwg = make_dxf(tmp_path / "E-301.dwg", [(layout, {"DWG_NO": "E-301"})],
                   setups={layout: {"device": "None", "size": (279.4, 215.9)}})
    scr = tmp_path / "plot.scr"
    scr.write_text(script, encoding="utf-8")
    env = {**os.environ, "VELLUM_FAKE_PLOT_SIT": "0"}
    env.pop("VELLUM_FAKE_PLOT_LOG", None)
    done = subprocess.run([sys.executable, str(FAKE), "ok", "/i", str(dwg), "/s", str(scr), "/l", "en-US"],
                          capture_output=True, text=True, env=env, timeout=60, check=False)
    info = tmp_path / "plot.txt"
    return (info.read_text(encoding="utf-8") if info.exists() else ""), done.stdout


def wrap_plot(script: str, before: str, after: str) -> str:
    """The script with its first detailed -PLOT command rewritten as ``before`` + its answers + ``after``."""
    from fake_plot_console import forms_starting

    plot = next(f for f in forms_starting(script, '(command "_.-PLOT" "_Y"'))
    return script.replace(plot, before + plot[len("(command "):-1] + after, 1)


def test_the_stand_in_refuses_a_command_inside_a_catch_or_an_error_handler_as_autocad_does(tmp_path):
    out, info = tmp_path / "plot.pdf", tmp_path / "plot.txt"
    script = plot_script("Layout1", out, info, "fallback", "ANSI full bleed A (8.50 x 11.00 Inches)", "Inches")
    report, _ = fake_run(tmp_path, script)
    assert "PLOTTED" in report.splitlines() and out.exists()  # the script as it is plots
    out.unlink()
    info.unlink()

    # -PLOT run through vl-catch-all-apply, as ae6cfa5 did: refused, reported FAILED, nothing plotted
    caught = wrap_plot(script, "(vl-catch-all-apply 'command (list ", "))")
    report, said = fake_run(tmp_path, caught)
    assert "bad order function: COMMAND" in said
    assert "FAILED\tbad order function: COMMAND" in report.splitlines() and "PLOTTED" not in report
    assert not out.exists()
    info.unlink()

    # a command in *error*: a cancelled plot's handler stops at it and never finishes the report
    calling = plot_script("Model", out, info, "fallback", "ANSI full bleed A (8.50 x 11.00 Inches)", "Inches")
    calling = calling.replace("(setq *error* (lambda (msg)", '(setq *error* (lambda (msg) (command "_.UNDO" "_E")')
    report, said = fake_run(tmp_path, calling, layout="Model")  # the layout's answers on the Model tab: cancelled
    assert "bad order function: COMMAND" in said and report == ""
    assert not out.exists()
