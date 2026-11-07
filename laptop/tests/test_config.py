import json
from pathlib import Path

import pytest

from vellum_indexer.config import ConfigError, Settings, dropbox_from_info_json, find_dropbox, load_settings


def info(tmp_path: Path, name: str, data: dict) -> Path:
    p = tmp_path / name / "Dropbox" / "info.json"
    p.parent.mkdir(parents=True)
    p.write_text(json.dumps(data))
    return p


def test_the_dropbox_folder_comes_from_dropboxs_info_json(tmp_path: Path):
    roaming = info(tmp_path, "Roaming", {"personal": {"path": "C:\\Users\\made-up\\Dropbox", "host": 1}})
    assert dropbox_from_info_json([tmp_path / "missing.json", roaming]) == Path("C:\\Users\\made-up\\Dropbox")


def test_personal_before_business_unless_settings_say_which(tmp_path: Path):
    both = info(tmp_path, "Local", {"business": {"path": "/b"}, "personal": {"path": "/p"}})
    assert dropbox_from_info_json([both]) == Path("/p")
    assert dropbox_from_info_json([both], "business") == Path("/b")
    only_business = info(tmp_path, "Other", {"business": {"path": "/b"}})
    assert dropbox_from_info_json([only_business]) == Path("/b")


def test_a_broken_info_json_is_skipped(tmp_path: Path):
    broken = tmp_path / "info.json"
    broken.write_text("{not json")
    assert dropbox_from_info_json([broken]) is None


def test_settings_file(tmp_path: Path):
    (tmp_path / "settings.toml").write_text(
        'dropbox_path = "D:/Dropbox"\nprojects_roots = ["/Work"]\nexclude = ["/Personal/**"]\n'
        'debounce_seconds = 5\n[title_block_tags]\nnumber = ["SHT_ID"]\n'
    )
    s = load_settings(tmp_path)
    assert s.dropbox_path == Path("D:/Dropbox") and s.projects_roots == ["/Work"]
    assert s.exclude == ["/Personal/**"] and s.debounce_seconds == 5.0
    assert s.title_block_tags == {"number": ["SHT_ID"]}
    assert load_settings(tmp_path / "none") == Settings()


def test_the_override_wins_and_a_missing_folder_is_an_error(tmp_path: Path):
    assert find_dropbox(Settings(dropbox_path=Path("/nope")), tmp_path) == tmp_path
    with pytest.raises(ConfigError):
        find_dropbox(Settings(dropbox_path=tmp_path / "gone"))
