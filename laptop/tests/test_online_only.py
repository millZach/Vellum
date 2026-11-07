"""Dropbox's online-only files are listed by path and name and never opened; once local, they are read once."""

from pathlib import Path

import pytest

from vellum_indexer import files
from vellum_indexer.index import read_index

from conftest import FakeOnlineOnly
from makers import PLANT, SCHOOL, small_tree, touch


@pytest.mark.parametrize(
    "attributes, online_only",
    [
        (0, False),
        (0x20, False),  # FILE_ATTRIBUTE_ARCHIVE: an ordinary local file
        (0x80000, False),  # FILE_ATTRIBUTE_PINNED: always kept on this laptop
        (files.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS, True),
        (files.FILE_ATTRIBUTE_RECALL_ON_OPEN, True),
        (files.FILE_ATTRIBUTE_OFFLINE, True),
        (0x20 | 0x100000 | files.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS, True),  # unpinned, online-only
    ],
)
def test_which_attributes_mean_online_only(attributes, online_only):
    assert files.is_online_only(attributes) is online_only


def test_online_only_files_are_listed_but_never_opened(dropbox: Path, make_indexer):
    small_tree(dropbox)
    online = FakeOnlineOnly()
    online.names = {"V-12 Pump skid GA.pdf", "E-202.dwg", "M-101.pdf"}
    previews = []

    def preview(path):
        previews.append(path.name)
        return None

    indexer = make_indexer(attributes=online, read_preview=preview)
    indexer.scan()
    opened = indexer.read_pdf.names() + [p.name for p in indexer.dwg_reader.read_paths] + previews
    assert not set(opened) & online.names, opened
    assert indexer.counters.online_only_listed == 3

    _, entries = read_index(dropbox / "Vellum" / "Index")
    e = {x["name"]: x for x in entries}
    vendor = e["V-12 Pump skid GA.pdf"]
    assert vendor["path"] == f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf"
    assert vendor["pdf"]["read"] is False
    assert vendor["pdf"]["contentHash"] is None and vendor["thumbnail"] is None
    assert (vendor["title"], vendor["revision"], vendor["scale"], vendor["date"]) == (None, None, None, None)
    assert vendor["number"] is None and vendor["fieldsFrom"] is None

    unread_dwg = e["E-202.dwg"]
    assert unread_dwg["dwg"]["read"] is False
    assert unread_dwg["number"] == "E-202" and unread_dwg["fieldsFrom"] == "name"  # from its file name only

    # an online-only PDF still pairs by its name, which needs no reading
    m101 = e["M-101.dwg"]
    assert m101["pdf"]["path"] == f"/{SCHOOL}/Mechanical/M-101.pdf" and m101["pdf"]["read"] is False
    assert m101["revision"] == "C"  # from the DWG, which is local


def test_an_online_only_file_is_read_once_it_is_local(dropbox: Path, make_indexer):
    small_tree(dropbox)
    online = FakeOnlineOnly()
    online.names = {"V-12 Pump skid GA.pdf"}
    indexer = make_indexer(attributes=online)
    indexer.scan()
    assert "V-12 Pump skid GA.pdf" not in indexer.read_pdf.names()

    # a rescan while it is still online-only does not read it
    indexer.read_pdf.paths.clear()
    indexer.scan()
    assert indexer.read_pdf.names() == []

    online.names = set()  # Zach opened it, or made it available offline
    indexer.scan()
    assert indexer.read_pdf.names() == ["V-12 Pump skid GA.pdf"]
    _, entries = read_index(dropbox / "Vellum" / "Index")
    vendor = next(x for x in entries if x["name"] == "V-12 Pump skid GA.pdf")
    assert vendor["pdf"]["read"] is True and vendor["title"] == "Pump skid general arrangement"

    indexer.read_pdf.paths.clear()
    indexer.scan()
    assert indexer.read_pdf.names() == []


def test_a_watched_change_to_an_online_only_file_does_not_open_it(dropbox: Path, make_indexer):
    small_tree(dropbox)
    online = FakeOnlineOnly()
    indexer = make_indexer(attributes=online)
    indexer.scan()
    pdf = dropbox / PLANT / "PDF" / "E-201.pdf"
    online.names = {"E-201.pdf"}  # freed up to online-only on the laptop: Dropbox swaps in a placeholder
    touch(pdf, 1_800_000_000)
    indexer.read_pdf.paths.clear()
    indexer.update({f"/{PLANT}/PDF/E-201.pdf"})
    assert indexer.read_pdf.names() == []


# --- Zach's decision (2026-11-07): download online-only files to the external drive, read them, delete the copy ---

import logging  # noqa: E402

from vellum_indexer.dropbox_api import DropboxClient, MemoryTokenStore  # noqa: E402
from vellum_indexer.scratch import Downloader  # noqa: E402

from makers import ScriptedDropbox, title_block_pdf  # noqa: E402

ONLINE = {"V-12 Pump skid GA.pdf", "E-202.dwg", "M-101.pdf"}


class Drive:
    def __init__(self):
        self.present = True

    def __call__(self, path):
        return self.present


def set_up(dropbox: Path, tmp_path: Path, signed_in: bool = True):
    small_tree(dropbox)
    server = ScriptedDropbox(dropbox)
    tokens = MemoryTokenStore(ScriptedDropbox.REFRESH if signed_in else None)
    client = DropboxClient(ScriptedDropbox.APP_KEY, tokens, transport=server, sleep=lambda s: None)
    drive = Drive()
    scratch = tmp_path / "D" / "Vellum indexer" / "scratch"
    downloader = Downloader(scratch, client, min_free_bytes=0, drive_present=drive)
    online = FakeOnlineOnly()
    online.names = set(ONLINE)
    return server, tokens, drive, scratch, downloader, online


def scratch_files(scratch: Path) -> list[str]:
    return sorted(p.name for p in scratch.iterdir()) if scratch.exists() else []


def test_an_online_only_file_is_downloaded_to_scratch_read_and_its_copy_deleted(dropbox, tmp_path, make_indexer):
    server, _, _, scratch, downloader, online = set_up(dropbox, tmp_path)
    previews = []

    def preview(path):
        previews.append(path)
        return None

    indexer = make_indexer(attributes=online, downloader=downloader, read_preview=preview)
    indexer.scan()
    assert sorted(server.downloads) == sorted([
        f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf", f"/{PLANT}/CAD/E-202.dwg", f"/{SCHOOL}/Mechanical/M-101.pdf"])
    # every reader was handed the copy in scratch, never the placeholder in the Dropbox folder
    handed = indexer.read_pdf.paths + indexer.dwg_reader.read_paths + previews
    for path in handed:
        if path.name in ONLINE:
            raise AssertionError(f"the placeholder {path} was opened")
    copies = [p for p in handed if p.parent == scratch]
    assert len(copies) == 4  # two PDFs, and a DWG's preview and title block
    assert scratch_files(scratch) == []  # each copy deleted once read
    _, entries = read_index(dropbox / "Vellum" / "Index")
    e = {x["name"]: x for x in entries}
    vendor = e["V-12 Pump skid GA.pdf"]
    assert vendor["pdf"]["read"] is True and vendor["title"] == "Pump skid general arrangement"
    assert vendor["pdf"]["path"] == f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf"  # the Dropbox path, not scratch
    assert len(vendor["pdf"]["contentHash"]) == 64 and vendor["thumbnail"]
    assert e["E-202.dwg"]["dwg"]["read"] is True and e["E-202.dwg"]["title"] == "Boiler room lighting plan"
    assert e["M-101.dwg"]["pdf"]["read"] is True


def test_an_unchanged_online_only_file_is_not_downloaded_again_and_a_changed_one_is(dropbox, tmp_path, make_indexer):
    server, _, _, scratch, downloader, online = set_up(dropbox, tmp_path)
    indexer = make_indexer(attributes=online, downloader=downloader)
    indexer.scan()
    server.downloads.clear()
    indexer.scan()
    from test_incremental import budget

    assert len(server.downloads) == budget("downloads_rescan_no_change") == 0
    # the vendor PDF changes in Dropbox; the laptop's placeholder takes its new size and time
    pdf = dropbox / PLANT / "Vendor" / "V-12 Pump skid GA.pdf"
    title_block_pdf(pdf, number="V-12", title="Pump skid general arrangement", rev="3", scale="1:20", inches=(17, 11))
    touch(pdf, 1_800_000_000)
    server.update(f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf", pdf.read_bytes())
    indexer.scan()
    assert server.downloads == [f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf"]
    assert len(server.downloads) == budget("downloads_one_online_only_changed") == 1
    assert len(scratch_files(scratch)) == budget("scratch_files_left_after_a_scan") == 0
    vendor = next(x for x in read_index(dropbox / "Vellum" / "Index")[1] if x["name"] == "V-12 Pump skid GA.pdf")
    assert vendor["revision"] == "3"


def test_a_copy_left_by_a_crash_is_deleted_at_start_and_nothing_else(dropbox, tmp_path, make_indexer):
    _, _, _, scratch, downloader, online = set_up(dropbox, tmp_path)
    scratch.mkdir(parents=True)
    (scratch / "vellum-dl-0a1b2c3d4e5f.pdf").write_bytes(b"half a made-up download")
    (scratch / "not ours.txt").write_text("made up")
    make_indexer(attributes=online, downloader=downloader)
    assert scratch_files(scratch) == ["not ours.txt"]


def test_with_no_drive_or_no_sign_in_files_stay_unread_and_are_read_when_they_come_back(
        dropbox, tmp_path, make_indexer, caplog):
    server, tokens, drive, scratch, downloader, online = set_up(dropbox, tmp_path, signed_in=False)
    caplog.set_level(logging.INFO, logger="vellum_indexer")
    drive.present = False
    indexer = make_indexer(attributes=online, downloader=downloader)
    indexer.scan()
    entries = read_index(dropbox / "Vellum" / "Index")[1]
    unread = sorted(x["name"] for x in entries
                    if (x["pdf"] and not x["pdf"]["read"]) or (x["dwg"] and not x["dwg"]["read"]))
    assert unread == ["E-202.dwg", "M-101.dwg", "V-12 Pump skid GA.pdf"]
    assert server.downloads == []
    why = [r.message for r in caplog.records if "stay unread" in r.message]
    assert why == ["Online-only files stay unread for now: the laptop is not signed in to Dropbox "
                   "(vellum-indexer sign-in)"]  # once, not once per file

    tokens.put(ScriptedDropbox.REFRESH)  # signed in; the drive still unplugged
    indexer.retry_unread()
    assert server.downloads == []
    why = [r.message for r in caplog.records if "stay unread" in r.message]
    assert why[-1].endswith("is not there") and len(why) == 2

    drive.present = True  # plugged back in
    indexer.retry_unread()
    assert len(server.downloads) == 3 and scratch_files(scratch) == []
    entries = read_index(dropbox / "Vellum" / "Index")[1]
    assert all((x["pdf"] is None or x["pdf"]["read"]) and (x["dwg"] is None or x["dwg"]["read"]) for x in entries)


def test_a_failed_download_leaves_nothing_in_scratch_and_is_tried_again(dropbox, tmp_path, make_indexer):
    server, _, _, scratch, downloader, online = set_up(dropbox, tmp_path)
    online.names = {"V-12 Pump skid GA.pdf"}
    server.fail = [500] * 6  # busy through every retry
    indexer = make_indexer(attributes=online, downloader=downloader)
    indexer.scan()
    assert scratch_files(scratch) == [] and server.downloads == []
    vendor = next(x for x in read_index(dropbox / "Vellum" / "Index")[1] if x["name"] == "V-12 Pump skid GA.pdf")
    assert vendor["pdf"]["read"] is False
    indexer.retry_unread()
    assert server.downloads == [f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf"] and scratch_files(scratch) == []


def test_a_download_cut_short_or_not_matching_its_hash_is_not_kept(dropbox, tmp_path):
    server, _, _, scratch, downloader, _ = set_up(dropbox, tmp_path)
    scratch.mkdir(parents=True)
    real = server.__call__

    def corrupt(url, headers, body):
        reply = real(url, headers, body)
        if reply.status == 200 and "dropbox-api-result" in reply.headers:
            import io

            reply.body = io.BytesIO(reply.body.read()[:-10] + b"0123456789")  # same size, other bytes
        return reply

    downloader.client.transport = corrupt
    import pytest as _pytest

    from vellum_indexer.dropbox_api import DropboxError

    with _pytest.raises(DropboxError):
        downloader.fetch(f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf", 100)
    assert scratch_files(scratch) == []


def test_busy_and_expired_answers_are_retried(dropbox, tmp_path):
    server, _, _, scratch, downloader, _ = set_up(dropbox, tmp_path)
    waits = []
    downloader.client.sleep = waits.append
    server.fail = [429, 503]
    copy = downloader.fetch(f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf", 100)
    assert copy.parent == scratch and copy.read_bytes() == server.files[f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf"]
    assert waits == [1.0, 2.0]  # Retry-After, then backoff
    Downloader.done(copy)
    server.issued.append("made-up-access-token-someone-else")  # the laptop's access token has lapsed
    copy = downloader.fetch(f"/{PLANT}/Vendor/V-12 Pump skid GA.pdf", 100)
    Downloader.done(copy)
    assert scratch_files(scratch) == []


def test_the_token_is_never_written_to_the_log_or_any_file(dropbox, tmp_path, make_indexer, caplog):
    server, tokens, _, scratch, downloader, online = set_up(dropbox, tmp_path, signed_in=False)
    log_file = tmp_path / "home" / "indexer.log"
    log_file.parent.mkdir(parents=True, exist_ok=True)
    handler = logging.FileHandler(log_file, encoding="utf-8")
    logger = logging.getLogger("vellum_indexer")
    logger.addHandler(handler)
    logger.setLevel(logging.DEBUG)
    caplog.set_level(logging.DEBUG, logger="vellum_indexer")
    try:
        from vellum_indexer.dropbox_api import pkce_pair

        verifier, challenge = pkce_pair()
        url = downloader.client.sign_in_url(challenge)
        assert "client_id=madeupappkey0000" in url and "code_challenge_method=S256" in url
        assert "token_access_type=offline" in url and "redirect_uri" not in url
        downloader.client.finish_sign_in(ScriptedDropbox.CODE, verifier)
        assert tokens.get() == ScriptedDropbox.REFRESH
        indexer = make_indexer(attributes=online, downloader=downloader)
        indexer.scan()
        server.fail = [500] * 6
        online.names = {"E-201.pdf"}
        touch(dropbox / PLANT / "PDF" / "E-201.pdf", 1_800_000_000)
        indexer.scan()  # a failure is logged too
        indexer.state.commit()
    finally:
        logger.removeHandler(handler)
        handler.close()
    secrets_ = [ScriptedDropbox.REFRESH, *server.issued]
    assert len(server.downloads) == 3
    for text in [caplog.text, log_file.read_text(encoding="utf-8")]:
        for secret in secrets_:
            assert secret not in text
    for path in tmp_path.rglob("*"):
        if path.is_file():
            data = path.read_bytes()
            for secret in secrets_:
                assert secret.encode() not in data, f"{secret[:12]}… found in {path}"
    downloader.client.sign_out()
    assert tokens.get() is None and server.revoked == 1


def test_the_refresh_token_goes_to_the_systems_credential_store():
    """On the Windows runner this is Windows Credential Manager; where there is no credential store it is skipped."""
    import keyring
    import pytest as _pytest

    from vellum_indexer.dropbox_api import KeyringTokenStore

    store = KeyringTokenStore("madeupappkey-test-only")
    try:
        store.put("made-up-refresh-token-for-the-store-test")
    except Exception as error:  # noqa: BLE001
        _pytest.skip(f"no credential store here: {type(error).__name__}")
    try:
        assert store.get() == "made-up-refresh-token-for-the-store-test"
        print(f"credential store: {type(keyring.get_keyring()).__module__}")
    finally:
        store.delete()
    assert store.get() is None


def test_freeing_a_read_file_to_online_only_or_back_downloads_and_reads_nothing(dropbox, tmp_path, make_indexer):
    server, _, _, scratch, downloader, online = set_up(dropbox, tmp_path)
    online.names = set()
    indexer = make_indexer(attributes=online, downloader=downloader)
    indexer.scan()
    indexer.read_pdf.paths.clear()
    online.names = {"E-201.pdf"}  # Dropbox → Make online-only: the attributes change, nothing else
    indexer.update({f"/{PLANT}/PDF/E-201.pdf"})
    online.names = set()  # and made available offline again
    indexer.update({f"/{PLANT}/PDF/E-201.pdf"})
    assert server.downloads == [] and indexer.read_pdf.paths == []
    e201 = next(x for x in read_index(dropbox / "Vellum" / "Index")[1] if x["name"] == "E-201.dwg")
    assert e201["pdf"]["read"] is True
