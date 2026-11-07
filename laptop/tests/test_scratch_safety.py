"""The scratch folder and downloads, made safe: AutoCAD's work copy of a downloaded DWG stays on the scratch drive, a
scratch folder inside Dropbox is refused, cleanup deletes only the indexer's own subfolder, interrupted downloads and
deletions mid-queue are handled, sign-out can't claim success while the token remains, the result is saved before the
copy goes, and a file made online-only just before its read is downloaded, not opened."""

import http.client
import io
import os
import sys
from pathlib import Path

import pytest

from test_online_only import ONLINE, scratch_files, set_up
from vellum_indexer import cli
from vellum_indexer.dropbox_api import DropboxClient, DropboxError, KeyringTokenStore, MemoryTokenStore
from vellum_indexer.dwg import AccoreconsoleReader
from vellum_indexer.files import FileFacts
from vellum_indexer.index import read_index
from vellum_indexer.scratch import OWN_FOLDER, Downloader

from makers import PLANT, SCHOOL, ScriptedDropbox, touch


def own(scratch: Path) -> Path:
    return scratch / OWN_FOLDER


# 1. An online-only DWG's work copy for AutoCAD stays on the scratch drive


def test_autocad_works_on_a_downloaded_dwg_inside_the_scratch_folder(dropbox, tmp_path, make_indexer):
    server, _, _, scratch, downloader, online = set_up(dropbox, tmp_path)
    online.names = {"E-202.dwg"}
    seen = []

    class Reader:
        id = "seen-1"

        def read(self, path, work=None):
            seen.append((path, work))
            return []

    make_indexer(attributes=online, downloader=downloader, dwg_reader=Reader()).scan()
    downloaded = [(p, w) for p, w in seen if p.name.startswith("vellum-dl-")]
    assert len(downloaded) == 1
    path, work = downloaded[0]
    assert work is not None and (work == own(scratch) or own(scratch) in work.parents)
    local = [(p, w) for p, w in seen if not p.name.startswith("vellum-dl-")]
    assert all(w is None for _, w in local)  # a local DWG keeps the reader's own work folder


def test_the_console_reader_uses_the_work_folder_it_is_given(tmp_path):
    from test_accoreconsole import fake_console, project_with_a_dwg

    dwg = project_with_a_dwg(tmp_path)
    home_work, scratch_work = tmp_path / "home" / "work", tmp_path / "D" / "scratch-work"
    seen = []
    import vellum_indexer.dwg as dwg_module

    real = dwg_module.subprocess.run

    def spy(args, **kwargs):
        seen.append(Path(kwargs["cwd"]).parent)
        return real(args, **kwargs)

    dwg_module.subprocess.run = spy
    try:
        AccoreconsoleReader(fake_console(tmp_path), home_work).read(dwg, work=scratch_work)
    finally:
        dwg_module.subprocess.run = real
    assert seen == [scratch_work] and not home_work.exists()


def test_startup_clears_leftover_work_folders_on_both_drives(dropbox, tmp_path, make_indexer):
    _, _, _, scratch, downloader, online = set_up(dropbox, tmp_path)
    home_work = tmp_path / "home" / "work"
    (home_work / "0a1b2c3d4e5f").mkdir(parents=True)
    (home_work / "0a1b2c3d4e5f" / "drawing.dwg").write_bytes(b"made up")
    reader = AccoreconsoleReader(["accoreconsole"], home_work)
    downloader.dropbox_root = dropbox
    assert downloader.available()  # makes its own subfolder
    (own(scratch) / "work" / "9f8e7d6c5b4a").mkdir(parents=True)
    (own(scratch) / "work" / "9f8e7d6c5b4a" / "drawing.dwg").write_bytes(b"made up")
    (own(scratch) / "vellum-dl-0a1b2c3d4e5f.dwg").write_bytes(b"made up")
    make_indexer(attributes=online, downloader=downloader, dwg_reader=reader)
    assert list(home_work.iterdir()) == []
    assert [p.name for p in own(scratch).iterdir()] == [".created-by-vellum-indexer"]


# 2. A scratch folder inside Dropbox is refused, and cleanup touches only the indexer's own subfolder


def test_a_scratch_folder_inside_dropbox_is_refused(dropbox, tmp_path, caplog):
    import logging

    caplog.set_level(logging.WARNING, logger="vellum_indexer")
    _, _, _, _, downloader, _ = set_up(dropbox, tmp_path)
    downloader.scratch = dropbox / "Projects" / "scratch"
    downloader.dropbox_root = dropbox
    assert not downloader.available()
    assert "inside the Dropbox folder" in downloader.reason
    assert any("inside the Dropbox folder" in r.message for r in caplog.records)
    with pytest.raises(Exception):  # noqa: B017
        downloader.fetch(f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf", 10)
    assert not (dropbox / "Projects" / "scratch").exists()
    downloader.scratch = dropbox
    assert not downloader.available()


def link_into(target: Path, link: Path) -> None:
    """A symlink, or on Windows without the right to make one, a junction."""
    try:
        os.symlink(target, link, target_is_directory=True)
    except OSError:
        if sys.platform != "win32":
            raise
        import _winapi

        _winapi.CreateJunction(str(target), str(link))


def test_a_scratch_folder_reached_through_a_link_into_dropbox_is_refused(dropbox, tmp_path):
    _, _, _, _, downloader, _ = set_up(dropbox, tmp_path)
    (dropbox / "Projects" / "made-up target").mkdir(parents=True)
    link = tmp_path / "D" / "looks like scratch"
    link.parent.mkdir(parents=True, exist_ok=True)
    link_into(dropbox / "Projects" / "made-up target", link)
    downloader.scratch = link
    downloader.dropbox_root = dropbox
    assert not downloader.available() and "inside the Dropbox folder" in downloader.reason
    downloader.scratch = link / "deeper"
    assert not downloader.available()


def test_cleanup_deletes_only_inside_its_own_subfolder(dropbox, tmp_path, make_indexer):
    _, _, _, scratch, downloader, online = set_up(dropbox, tmp_path)
    scratch.mkdir(parents=True)
    (scratch / "vellum-dl-0a1b2c3d4e5f.pdf").write_bytes(b"a made-up look-alike, not ours")
    stranger = scratch / OWN_FOLDER
    stranger.mkdir()
    (stranger / "vellum-dl-111111111111.pdf").write_bytes(b"in a folder we never made")
    make_indexer(attributes=online, downloader=downloader)
    assert (scratch / "vellum-dl-0a1b2c3d4e5f.pdf").exists()
    assert (stranger / "vellum-dl-111111111111.pdf").exists()  # no marker: not the indexer's folder
    downloader.clean()
    assert (stranger / "vellum-dl-111111111111.pdf").exists()


def test_cleanup_refuses_a_scratch_folder_inside_dropbox(dropbox, tmp_path, make_indexer):
    _, _, _, _, downloader, online = set_up(dropbox, tmp_path)
    inside = dropbox / "Projects" / "scratch"
    (inside / OWN_FOLDER).mkdir(parents=True)
    (inside / OWN_FOLDER / ".created-by-vellum-indexer").write_text("")
    (inside / OWN_FOLDER / "vellum-dl-222222222222.pdf").write_bytes(b"made up")
    downloader.scratch = inside
    make_indexer(attributes=online, downloader=downloader)
    assert (inside / OWN_FOLDER / "vellum-dl-222222222222.pdf").exists()


# 4. An interrupted download is a failed download


class Broken(io.RawIOBase):
    def __init__(self, data, error):
        self.data, self.error, self.sent = data, error, False

    def read(self, n=-1):
        if not self.sent:
            self.sent = True
            return self.data[: len(self.data) // 2]
        raise self.error


@pytest.mark.parametrize("error", [http.client.IncompleteRead(b"x", 100), ConnectionResetError("made-up reset")])
def test_an_interrupted_download_is_retried_and_leaves_nothing(dropbox, tmp_path, make_indexer, error):
    server, _, _, scratch, downloader, online = set_up(dropbox, tmp_path)
    online.names = {"V-12 Pump skid GA.pdf"}
    real = server.__call__
    breaks = {"left": 2}
    waits = []
    downloader.client.sleep = waits.append

    def flaky(url, headers, body):
        reply = real(url, headers, body)
        if reply.status == 200 and "dropbox-api-result" in reply.headers and breaks["left"]:
            breaks["left"] -= 1
            reply.body = Broken(reply.body.read(), error)
        return reply

    downloader.client.transport = flaky
    indexer = make_indexer(attributes=online, downloader=downloader)
    indexer.scan()  # two interruptions, then it comes through
    assert len(waits) == 2 and scratch_files(scratch) == []
    vendor = next(x for x in read_index(dropbox / "Vellum" / "Index")[1] if x["name"] == "V-12 Pump skid GA.pdf")
    assert vendor["pdf"]["read"] is True

    breaks["left"] = 100  # now it never comes through
    touch(dropbox / PLANT / "Vendor" / "V-12 Pump skid GA.pdf", 1_800_000_000)
    indexer.scan()
    assert [p for p in own(scratch).iterdir() if p.name.startswith("vellum-dl-")] == []
    vendor = next(x for x in read_index(dropbox / "Vellum" / "Index")[1] if x["name"] == "V-12 Pump skid GA.pdf")
    assert vendor["pdf"]["read"] is False


# 5. A deleted file's queued read is dropped


def test_a_file_deleted_while_queued_does_not_come_back(dropbox, tmp_path, make_indexer):
    server, _, _, scratch, downloader, online = set_up(dropbox, tmp_path)
    indexer = make_indexer(attributes=online, downloader=downloader)
    gone = dropbox / PLANT / "Vendor" / "V-12 Pump skid GA.pdf"
    polls = []

    def poll():
        polls.append(1)
        if len(polls) == 1:
            gone.unlink()
            return ({f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf"}, set())
        return None

    indexer.poll_changes = poll
    indexer.scan()
    names = {x["name"] for x in read_index(dropbox / "Vellum" / "Index")[1]}
    assert "V-12 Pump skid GA.pdf" not in names
    assert f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf" not in server.downloads


# 6. Sign-out can't claim success while the token remains


class StuckKeyring:
    def __init__(self):
        self.saved = {("Vellum laptop indexer", "dropbox:madeupappkey0000"): ScriptedDropbox.REFRESH}

    def get_password(self, service, user):
        return self.saved.get((service, user))

    def set_password(self, service, user, value):
        self.saved[(service, user)] = value

    def delete_password(self, service, user):
        raise RuntimeError("made-up: Credential Manager refused")


def test_sign_out_says_so_and_fails_when_the_token_cant_be_removed(monkeypatch, tmp_path, capsys):
    import keyring

    stuck = StuckKeyring()
    for name in ("get_password", "set_password", "delete_password"):
        monkeypatch.setattr(keyring, name, getattr(stuck, name))
    store = KeyringTokenStore("madeupappkey0000")
    client = DropboxClient("madeupappkey0000", store, transport=ScriptedDropbox(tmp_path))
    with pytest.raises(DropboxError, match="still holds"):
        client.sign_out()
    monkeypatch.setattr(cli, "dropbox_client", lambda settings: client)
    assert cli.sign_out(tmp_path) != 0
    assert "still holds" in capsys.readouterr().out
    assert store.get() == ScriptedDropbox.REFRESH


def test_sign_out_of_a_store_that_lets_go_succeeds(tmp_path):
    store = MemoryTokenStore(ScriptedDropbox.REFRESH)
    DropboxClient("madeupappkey0000", store, transport=ScriptedDropbox(tmp_path)).sign_out()
    assert store.get() is None


# 7. The result is saved before the copy is deleted


def test_the_result_is_saved_before_the_copy_is_deleted(dropbox, tmp_path, make_indexer, monkeypatch):
    server, _, _, scratch, downloader, online = set_up(dropbox, tmp_path)
    online.names = {"V-12 Pump skid GA.pdf"}
    indexer = make_indexer(attributes=online, downloader=downloader)
    saved_when_deleted = []
    real_done = Downloader.done

    def done(copy):
        record = indexer.state.get(f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf".lower())
        saved_when_deleted.append(record is not None and record.reader != "unread")
        real_done(copy)

    monkeypatch.setattr(Downloader, "done", staticmethod(done))
    indexer.scan()
    assert saved_when_deleted == [True]


# 8. A file made online-only just before its read is downloaded, not opened


def test_a_file_made_online_only_before_its_read_is_downloaded_not_opened(dropbox, tmp_path, make_indexer):
    server, _, _, scratch, downloader, online = set_up(dropbox, tmp_path)
    online.names = set()
    indexer = make_indexer(attributes=online, downloader=downloader)
    pdf = dropbox / SCHOOL / "Mechanical" / "M-101.pdf"
    st = pdf.stat()
    queued = FileFacts(f"/{SCHOOL}/Mechanical/M-101.pdf", st.st_size, st.st_mtime_ns, False)  # local when listed
    online.names = {"M-101.pdf"}  # freed up between the event and the read
    indexer.take(queued)
    assert server.downloads == [f"/{SCHOOL}/Mechanical/M-101.pdf"]
    assert all(p.parent == own(scratch) for p in indexer.read_pdf.paths)
    record = indexer.state.get(queued.path.lower())
    assert record.online_only is True and record.reader != "unread"


assert ONLINE  # the names set_up marks online-only
