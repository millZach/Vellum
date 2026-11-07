"""Where things are on the laptop: the Dropbox folder, the indexer's own folder, and its settings.

The Dropbox folder comes from Dropbox's own info.json (``%APPDATA%\\Dropbox\\info.json`` or
``%LOCALAPPDATA%\\Dropbox\\info.json``), unless the settings file or the command line names one. The indexer's own
folder (state, log, settings, work copies of DWGs) is ``%LOCALAPPDATA%\\Vellum\\indexer``, never inside Dropbox;
``VELLUM_INDEXER_HOME`` moves it (tests and CI).
"""

from __future__ import annotations

import json
import os
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path


class ConfigError(Exception):
    pass


def indexer_home() -> Path:
    override = os.environ.get("VELLUM_INDEXER_HOME")
    if override:
        return Path(override)
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        return Path(base) / "Vellum" / "indexer"
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "vellum-indexer"


def info_json_candidates() -> list[Path]:
    paths = []
    for var in ("APPDATA", "LOCALAPPDATA"):
        base = os.environ.get(var)
        if base:
            paths.append(Path(base) / "Dropbox" / "info.json")
    if sys.platform != "win32":
        paths.append(Path.home() / ".dropbox" / "info.json")
    return paths


def dropbox_from_info_json(candidates: list[Path], account: str | None = None) -> Path | None:
    """The Dropbox folder named in the first info.json that has one: the account asked for, else personal, else
    business."""
    for candidate in candidates:
        try:
            info = json.loads(candidate.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        order = [account] if account else ["personal", "business"]
        for name in order:
            path = (info.get(name) or {}).get("path")
            if path:
                return Path(path)
    return None


@dataclass
class Settings:
    """``settings.toml`` in the indexer's folder; every key is optional."""

    dropbox_path: Path | None = None
    dropbox_account: str | None = None
    # Dropbox paths (``/Projects``) whose top folders are projects. Elsewhere a project is found by walking up past
    # discipline and format folders (projects.py).
    projects_roots: list[str] = field(default_factory=lambda: ["/Projects"])
    # Globs on Dropbox paths, matched case-insensitively (``/Personal/**``, ``**/Archive/**``).
    exclude: list[str] = field(default_factory=list)
    accoreconsole: Path | None = None
    # Extra title block attribute tags, per field: {"number": ["SHT_NO"], ...}.
    title_block_tags: dict[str, list[str]] = field(default_factory=dict)
    debounce_seconds: float = 2.0
    debounce_max_seconds: float = 30.0
    # A full stat-only rescan this often while watching, in case a change notification was lost.
    rescan_hours: float = 6.0


def load_settings(home: Path) -> Settings:
    path = home / "settings.toml"
    if not path.exists():
        return Settings()
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8-sig"))  # PowerShell 5 writes a BOM
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise ConfigError(f"{path} could not be read: {error}") from error
    settings = Settings()
    if "dropbox_path" in data:
        settings.dropbox_path = Path(data["dropbox_path"])
    if "dropbox_account" in data:
        settings.dropbox_account = str(data["dropbox_account"])
    if "projects_roots" in data:
        settings.projects_roots = [str(p) for p in data["projects_roots"]]
    if "exclude" in data:
        settings.exclude = [str(p) for p in data["exclude"]]
    if "accoreconsole" in data:
        settings.accoreconsole = Path(data["accoreconsole"])
    if "title_block_tags" in data:
        settings.title_block_tags = {str(k): [str(t) for t in v] for k, v in data["title_block_tags"].items()}
    for key in ("debounce_seconds", "debounce_max_seconds", "rescan_hours"):
        if key in data:
            setattr(settings, key, float(data[key]))
    return settings


def find_dropbox(settings: Settings, override: Path | None = None) -> Path:
    path = override or settings.dropbox_path or dropbox_from_info_json(info_json_candidates(), settings.dropbox_account)
    if path is None:
        raise ConfigError(
            "No Dropbox folder: Dropbox's info.json was not found. "
            "Name it with --dropbox or dropbox_path in settings.toml."
        )
    if not path.is_dir():
        raise ConfigError(f"The Dropbox folder {path} does not exist.")
    return path
