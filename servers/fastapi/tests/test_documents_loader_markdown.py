import asyncio
from unittest.mock import patch, MagicMock

import pytest

from services.documents_loader import (
    DocumentsLoader,
    _read_markdown_file_sync,
    _strip_optional_yaml_front_matter,
)


def test_strip_optional_yaml_front_matter_removes_block():
    raw = "---\ntitle: Doc\n---\n\n# Heading\n\nbody"
    out = _strip_optional_yaml_front_matter(raw)
    assert "title:" not in out
    assert "# Heading" in out
    assert "body" in out


def test_strip_optional_yaml_front_matter_unchanged_without_delimiter():
    raw = "# Title only\n\nno front matter"
    assert _strip_optional_yaml_front_matter(raw) == raw


def test_read_markdown_file_sync_utf8(tmp_path):
    f = tmp_path / "note.md"
    f.write_text("章节一\n", encoding="utf-8")
    assert _read_markdown_file_sync(str(f)) == "章节一\n"


@pytest.fixture
def mock_docling():
    with patch(
        "services.documents_loader.DoclingService",
        return_value=MagicMock(),
    ):
        yield


def test_load_documents_parses_markdown_file(tmp_path, mock_docling):
    md = tmp_path / "doc.md"
    md.write_text("---\nx: 1\n---\n\n# Hello\n", encoding="utf-8")

    loader = DocumentsLoader([str(md)])
    asyncio.run(loader.load_documents())

    assert len(loader.documents) == 1
    assert loader.documents[0].strip() == "# Hello"
    assert loader.images == [[]]
