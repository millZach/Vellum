"""The AutoCAD reader, with a stand-in for accoreconsole.exe: a Python script that acts on the same arguments and
writes the dump the LISP would, from a made-up DXF. Proves the DWG in the project folder is only copied, never opened
or written beside, and that the dump is read back as title block fields."""

import sys
import textwrap
from pathlib import Path

import pytest

from vellum_indexer.dwg import DUMP_LISP, AccoreconsoleReader, BlockInsert, ReaderError, dump_script, parse_dump
from vellum_indexer.fields import from_attributes

from makers import make_dxf

FAKE_CONSOLE = textwrap.dedent(r'''
    import sys, re, pathlib
    sys.path[:0] = [r"{tests}"]
    args = sys.argv[1:]
    drawing = pathlib.Path(args[args.index("/i") + 1])
    script = pathlib.Path(args[args.index("/s") + 1]).read_text()
    out = re.search(r'\(vellum-dump "([^"]+)"\)', script).group(1)
    (drawing.parent / (drawing.stem + ".dwl")).write_text("lock")  # AutoCAD's lock file, beside what it opened
    mode = "{mode}"
    if mode == "hang":
        import time; time.sleep(30)
    from makers import DxfReader
    lines = []
    if mode != "nothing":
        for ins in DxfReader().read(drawing):
            lines.append("INSERT\t" + ins.layout + "\t" + ins.block)
            lines += ["ATTRIB\t" + t + "\t" + v for t, v in ins.attributes.items()]
    if mode != "cut":
        lines.append("END")
    if mode != "nothing":
        pathlib.Path(out).write_text("\n".join(lines) + "\n", encoding="utf-8")
''')


def fake_console(tmp_path: Path, mode: str = "ok") -> list[str]:
    script = tmp_path / f"fake_accoreconsole_{mode}.py"
    script.write_text(FAKE_CONSOLE.format(tests=str(Path(__file__).parent), mode=mode))
    return [sys.executable, str(script)]


def project_with_a_dwg(tmp_path: Path) -> Path:
    return make_dxf(tmp_path / "Dropbox" / "Projects" / "Made-up Plant" / "E-201.dwg", [
        ("Layout1", {"DWG_NO": "E-201", "TITLE": "Boiler room power plan", "REV": "A"})])


def test_reads_attributes_from_a_copy_and_leaves_the_project_folder_alone(tmp_path: Path):
    dwg = project_with_a_dwg(tmp_path)
    before = sorted(p.name for p in dwg.parent.iterdir())
    original = dwg.read_bytes()
    work = tmp_path / "home" / "work"
    inserts = AccoreconsoleReader(fake_console(tmp_path), work).read(dwg)
    block = from_attributes(inserts)
    assert (block.number, block.title, block.revision) == ("E-201", "Boiler room power plan", "A")
    assert sorted(p.name for p in dwg.parent.iterdir()) == before  # no .dwl beside the original
    assert dwg.read_bytes() == original
    assert list(work.iterdir()) == []  # the copy and its lock file are cleaned up


@pytest.mark.parametrize("mode, message", [("cut", "incomplete"), ("nothing", "no attribute dump")])
def test_a_dump_cut_short_or_missing_is_an_error_not_empty_fields(tmp_path: Path, mode, message):
    dwg = project_with_a_dwg(tmp_path)
    with pytest.raises(ReaderError, match=message):
        AccoreconsoleReader(fake_console(tmp_path, mode), tmp_path / "work").read(dwg)


def test_a_hung_console_is_stopped(tmp_path: Path):
    dwg = project_with_a_dwg(tmp_path)
    with pytest.raises(ReaderError, match="longer than"):
        AccoreconsoleReader(fake_console(tmp_path, "hang"), tmp_path / "work", timeout=2).read(dwg)


def test_parse_dump():
    text = "INSERT\tLayout1\tTB\r\nATTRIB\tDWG_NO\tE-201\r\nATTRIB\tTITLE\tA\tB\r\nINSERT\tModel\tTAG\nEND\n"
    assert parse_dump(text) == [
        BlockInsert("Layout1", "TB", {"DWG_NO": "E-201", "TITLE": "A\tB"}),
        BlockInsert("Model", "TAG", {}),
    ]


def test_the_lisp_never_saves():
    lisp = DUMP_LISP.upper()
    for command in ("QSAVE", "SAVEAS", "WBLOCK", "(COMMAND"):
        assert command not in lisp
    assert '"_X"' in DUMP_LISP and "(66 . 1)" in DUMP_LISP


def test_the_script_loads_no_file_so_secureload_never_asks(tmp_path: Path):
    script = dump_script(tmp_path / "attributes.txt")
    lowered = script.lower()
    for loader in ("(load", "appload", "(autoload", "(arxload", ".lsp", ".fas", ".vlx", "secureload", "trustedpaths"):
        assert loader not in lowered
    lines = script.splitlines()
    # each form is whole on its own line (a line break in a script is Enter), and the escapes survive
    for line in lines[:2]:
        assert line.startswith("(defun ") and line.count("(") == line.count(")")
    assert '"\\t"' in lines[0] and "\t" not in script.replace("\\t", "")
    assert lines[2:] == [f'(vellum-dump "{(tmp_path / "attributes.txt").as_posix()}")', "_.QUIT", "_Y"]


def test_the_work_folder_holds_only_the_copy_and_the_script_while_autocad_runs(tmp_path: Path):
    dwg = project_with_a_dwg(tmp_path)
    work = tmp_path / "work"
    seen = []
    import vellum_indexer.dwg as dwg_module

    real_run = dwg_module.subprocess.run

    def spy(args, **kwargs):
        seen.extend(sorted(p.name for p in Path(kwargs["cwd"]).iterdir()))
        return real_run(args, **kwargs)

    dwg_module.subprocess.run = spy
    try:
        AccoreconsoleReader(fake_console(tmp_path), work).read(dwg)
    finally:
        dwg_module.subprocess.run = real_run
    assert seen == ["drawing.dwg", "dump.scr"]
