"""``vellum-indexer run | scan | where``.

- ``run``: scan, then watch Dropbox and keep the index up to date. What the logon task starts.
- ``scan``: scan once, publish, and exit.
- ``where``: print the Dropbox folder, the index folder, the indexer's own folder and the DWG reader, and exit.
"""

from __future__ import annotations

import argparse
import contextlib
import logging
import logging.handlers
import os
import sys
from pathlib import Path

from vellum_indexer import __version__, dwg, fields, files
from vellum_indexer.config import ConfigError, Settings, find_dropbox, indexer_home, load_settings
from vellum_indexer.dropbox_api import DropboxClient, DropboxError, KeyringTokenStore, pkce_pair
from vellum_indexer.indexer import Indexer
from vellum_indexer.projects import ProjectFinder
from vellum_indexer.scratch import Downloader
from vellum_indexer.state import State

log = logging.getLogger("vellum_indexer")


def set_up_logging(home: Path, verbose: bool) -> Path:
    home.mkdir(parents=True, exist_ok=True)
    path = home / "indexer.log"
    handler = logging.handlers.RotatingFileHandler(path, maxBytes=5 * 1024 * 1024, backupCount=3, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    root = logging.getLogger("vellum_indexer")
    root.setLevel(logging.DEBUG if verbose else logging.INFO)
    root.addHandler(handler)
    if sys.stderr is not None:  # pythonw has no console
        console = logging.StreamHandler()
        console.setFormatter(logging.Formatter("%(message)s"))
        root.addHandler(console)
    return path


def lower_priority() -> None:
    """Gentle on the laptop: Windows' background mode (low CPU, disk and memory priority), else nice."""
    if sys.platform == "win32":
        import ctypes

        process_mode_background_begin = 0x00100000
        kernel32 = ctypes.windll.kernel32
        if not kernel32.SetPriorityClass(kernel32.GetCurrentProcess(), process_mode_background_begin):
            kernel32.SetPriorityClass(kernel32.GetCurrentProcess(), 0x00004000)  # below normal
    else:
        with contextlib.suppress(OSError):
            os.nice(10)


class SingleInstance:
    """One indexer at a time: a lock on a file in the indexer's folder."""

    def __init__(self, path: Path):
        self.file = open(path, "a+")  # noqa: SIM115 - held for the life of the process
        try:
            if sys.platform == "win32":
                import msvcrt

                self.file.seek(0)
                msvcrt.locking(self.file.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(self.file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            self.file.close()
            raise ConfigError("Another laptop indexer is already running.") from error


def dropbox_client(settings: Settings) -> DropboxClient | None:
    if not settings.dropbox_app_key:
        return None
    return DropboxClient(settings.dropbox_app_key, KeyringTokenStore(settings.dropbox_app_key))


def make_downloader(settings: Settings) -> Downloader:
    return Downloader(settings.scratch_folder, dropbox_client(settings),
                      min_free_bytes=int(settings.scratch_min_free_gb * 1024**3))


def make_indexer(home: Path, dropbox: Path | None) -> tuple[Indexer, str, Settings]:
    settings = load_settings(home)
    root = find_dropbox(settings, dropbox)
    console = dwg.find_accoreconsole(settings.accoreconsole)
    reader = dwg.AccoreconsoleReader([str(console)], home / "work") if console else dwg.NoReader()
    described = f"AutoCAD core console at {console}" if console else "none (no accoreconsole.exe found)"
    indexer = Indexer(
        root,
        State(home / "state.sqlite"),
        rules=files.SkipRules(settings.exclude),
        projects=ProjectFinder(settings.projects_roots),
        dwg_reader=reader,
        tags=fields.TagMap(settings.title_block_tags),
        downloader=make_downloader(settings),
    )
    return indexer, described, settings


def sign_in(home: Path) -> int:
    """PKCE with no redirect URI: Dropbox shows a code, pasted here. The refresh token goes to Windows Credential
    Manager; nothing about it is printed or logged."""
    settings = load_settings(home)
    client = dropbox_client(settings)
    if client is None:
        raise ConfigError("Set dropbox_app_key in settings.toml first (install.ps1 -DropboxAppKey does it).")
    verifier, challenge = pkce_pair()
    print("Open this page, allow Vellum, and paste the code Dropbox shows:")
    print(client.sign_in_url(challenge))
    code = input("Code: ").strip()
    if not code:
        print("No code; not signed in.")
        return 1
    client.finish_sign_in(code, verifier)
    print("Signed in. The laptop indexer can now download online-only files to read them.")
    return 0


def sign_out(home: Path) -> int:
    client = dropbox_client(load_settings(home))
    if client is None or not client.signed_in():
        print("Not signed in.")
        return 0
    client.sign_out()
    print("Signed out: the token is removed from Windows Credential Manager.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="vellum-indexer", description="Vellum's laptop indexer.")
    parser.add_argument("command", choices=["run", "scan", "where", "sign-in", "sign-out"])
    parser.add_argument("--dropbox", type=Path, help="the Dropbox folder, instead of Dropbox's info.json")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    home = indexer_home()
    try:
        if args.command == "sign-in":
            return sign_in(home)
        if args.command == "sign-out":
            return sign_out(home)
        if args.command == "where":
            indexer, reader, settings = make_indexer(home, args.dropbox)
            print(f"Dropbox folder: {indexer.root}")
            print(f"Index folder:   {indexer.index_folder}")
            print(f"Indexer folder: {home} (state.sqlite, indexer.log, settings.toml)")
            print(f"DWG reader:     {reader}")
            d = indexer.downloader
            d.available()
            print(f"Online-only:    downloaded to {d.scratch}, read, deleted" if d.reason is None
                  else f"Online-only:    listed unread ({d.reason})")
            return 0
        log_path = set_up_logging(home, args.verbose)
        lock = SingleInstance(home / "indexer.lock")  # noqa: F841 - held until exit
        lower_priority()
        indexer, reader, settings = make_indexer(home, args.dropbox)
        log.info("Vellum laptop indexer %s: Dropbox %s, index %s, DWG reader %s, log %s",
                 __version__, indexer.root, indexer.index_folder, reader, log_path)
        if args.command == "scan":
            indexer.scan()
            return 0
        from vellum_indexer.watch import watch

        watch(indexer, settings.debounce_seconds, settings.debounce_max_seconds, settings.rescan_hours,
              retry_minutes=settings.retry_unread_minutes)
        return 0
    except (ConfigError, DropboxError) as error:
        log.error("%s", error)
        return 2
    except KeyboardInterrupt:
        return 0
