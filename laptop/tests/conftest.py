from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

from vellum_indexer import files  # noqa: E402
from vellum_indexer import pdf as pdf_module  # noqa: E402
from vellum_indexer.indexer import Indexer  # noqa: E402
from vellum_indexer.state import State  # noqa: E402

from makers import DxfReader  # noqa: E402


class Spy:
    """Wraps a reader and records every path it was handed: proof a file was, or was never, opened."""

    def __init__(self, fn):
        self.fn = fn
        self.paths: list[Path] = []

    def __call__(self, path: Path):
        self.paths.append(Path(path))
        return self.fn(path)

    def names(self) -> list[str]:
        return [p.name for p in self.paths]


class FakeOnlineOnly:
    """Windows' online-only attributes, faked: the files named here report FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS."""

    def __init__(self):
        self.names: set[str] = set()

    def __call__(self, path: Path, st) -> int:
        attributes = files.attributes_of(st)
        if path.name in self.names:
            attributes |= files.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS | files.FILE_ATTRIBUTE_OFFLINE
        return attributes


@pytest.fixture
def dropbox(tmp_path: Path) -> Path:
    root = tmp_path / "Dropbox"
    root.mkdir()
    return root


@pytest.fixture
def make_indexer(tmp_path: Path, dropbox: Path):
    made = []

    def make(**kwargs) -> Indexer:
        kwargs.setdefault("dwg_reader", DxfReader())
        kwargs.setdefault("read_pdf", Spy(pdf_module.read_pdf))
        state = State(tmp_path / "home" / "state.sqlite")
        indexer = Indexer(dropbox, state, **kwargs)
        made.append(indexer)
        return indexer

    yield make
    for indexer in made:
        indexer.state.close()
