"""Watching Dropbox: debounced, so a folder copy is one update, and a saved PDF reaches the index within seconds."""

import shutil
import threading
import time
from pathlib import Path

from vellum_indexer.files import SkipRules
from vellum_indexer.index import read_index
from vellum_indexer.watch import Debouncer, DropboxEvents, watch

from makers import PLANT, make_pdf, small_tree, title_block_pdf
from test_incremental import budget


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


def test_the_debouncer_waits_for_quiet_and_never_past_its_cap():
    clock = Clock()
    d = Debouncer(quiet=2, max_wait=30, clock=clock)
    assert not d.due()
    for i in range(10):  # a copy: an event every half second for five seconds
        d.add(f"/P/{i}.pdf")
        clock.now += 0.5
        assert not d.due()
    clock.now += 1.5
    assert d.due()
    paths, folders = d.take()
    assert len(paths) == 10 and folders == set() and not d.due()
    start = clock.now
    for _ in range(100):  # a copy that never pauses still lands every 30 s
        d.add("/P/x.pdf")
        clock.now += 1
        if d.due():
            break
    assert clock.now - start == 30


def test_events_become_dropbox_paths_and_vellums_own_writes_are_left_out(dropbox: Path):
    d = Debouncer()
    events = DropboxEvents(dropbox, SkipRules(), d)
    events.handle("modified", str(dropbox / "Projects" / "P" / "E-1.pdf"), None, False)
    events.handle("created", str(dropbox / "Projects" / "P" / "~$E-1.dwg"), None, False)
    events.handle("modified", str(dropbox / "Projects" / "P" / "E-1.dwl"), None, False)
    events.handle("modified", str(dropbox / "Vellum" / "Index" / "index.json"), None, False)
    events.handle("modified", str(dropbox / "Projects" / "P"), None, True)
    events.handle("moved", str(dropbox / "Projects" / "Old"), str(dropbox / "Projects" / "New"), True)
    events.handle("moved", str(dropbox / "Projects" / "P" / "a.tmp"), str(dropbox / "Projects" / "P" / "E-2.dwg"), False)
    events.handle("created", "/somewhere/else/E-3.pdf", None, False)
    paths, folders = d.take()
    assert paths == {"/Projects/P/E-1.pdf", "/Projects/P/E-2.dwg"}
    assert folders == {"/Projects/Old", "/Projects/New"}


def run_watcher(indexer, quiet=0.5):
    stop = threading.Event()
    updates = []
    real = indexer.update

    def counted(*args, **kwargs):
        updates.append(args)
        return real(*args, **kwargs)

    indexer.update = counted
    thread = threading.Thread(target=watch, args=(indexer, quiet, 10, 24, stop), daemon=True)
    thread.start()
    return stop, thread, updates


def wait_for(condition, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return False


def test_a_saved_pdf_reaches_the_index_and_a_folder_copy_is_one_update(dropbox: Path, make_indexer, tmp_path):
    small_tree(dropbox)
    indexer = make_indexer()
    index = dropbox / "Vellum" / "Index"
    stop, thread, updates = run_watcher(indexer)
    try:
        assert wait_for(lambda: (index / "index.json").exists())
        generation = read_index(index)[0]["generation"]

        saved = time.monotonic()
        title_block_pdf(dropbox / PLANT / "PDF" / "E-201.pdf", number="E-201", title="Boiler room power plan",
                        rev="B", mark=4, title_meta="E-201-Layout1")
        assert wait_for(lambda: read_index(index)[0]["generation"] > generation)
        assert time.monotonic() - saved < 10
        e201 = next(e for e in read_index(index)[1] if e["name"] == "E-201.dwg")
        assert e201["pdf"]["contentHash"] is not None

        source = tmp_path / "copy-source" / "Made-up Dam"
        for i in range(40):
            make_pdf(source / "PDF" / f"C-{i:03}.pdf", inches=(11, 8.5), mark=i % 7)
        updates.clear()
        shutil.copytree(source, dropbox / "Projects" / "Made-up Dam")
        assert wait_for(lambda: read_index(index)[0]["drawings"] == 44)
        time.sleep(1.5)  # any straggling update would land by now
        assert len(updates) == budget("index_updates_for_a_folder_copy") == 1
    finally:
        stop.set()
        thread.join(10)
