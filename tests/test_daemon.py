"""Tests for the daemon request handling."""

from __future__ import annotations

import pytest

from aish.config import AishConfig
from aish.daemon import AishDaemon, SessionBuffer, _ensure_leading_space


class TestEnsureLeadingSpace:
    def test_adds_space_between_word_and_flag(self) -> None:
        assert _ensure_leading_space("ffmpeg", "-i input.mp4") == " -i input.mp4"

    def test_no_space_when_suggestion_starts_with_space(self) -> None:
        assert _ensure_leading_space("git", " status") == " status"

    def test_no_space_when_buffer_ends_with_space(self) -> None:
        assert _ensure_leading_space("git ", "status") == "status"

    def test_empty_suggestion(self) -> None:
        assert _ensure_leading_space("git", "") == ""

    def test_empty_buffer(self) -> None:
        assert _ensure_leading_space("", "ls") == "ls"

    def test_pipe_after_space(self) -> None:
        # Buffer ends with non-word char (space after 'foo' would be in buffer)
        assert _ensure_leading_space("grep foo ", "| wc -l") == "| wc -l"

    def test_pipe_no_space(self) -> None:
        # `|` is not in the trigger list, so no space added
        assert _ensure_leading_space("grep foo", "| wc -l") == "| wc -l"


class TestSessionBuffer:
    def test_add_and_format(self) -> None:
        buf = SessionBuffer()
        buf.add("git status", "M src/main.py\nM src/test.py")
        result = buf.format_for_prompt()
        assert "git status" in result
        assert "src/main.py" in result

    def test_max_entries(self) -> None:
        buf = SessionBuffer()
        for i in range(25):
            buf.add(f"cmd{i}", f"output{i}")
        assert len(buf.entries) == 20

    def test_output_truncation(self) -> None:
        buf = SessionBuffer()
        long_output = "\n".join(f"line{i}" for i in range(50))
        buf.add("long-cmd", long_output)
        entry = buf.entries[0]
        assert entry.output.count("\n") < 50

    def test_empty_buffer(self) -> None:
        buf = SessionBuffer()
        assert buf.format_for_prompt() == ""


class TestDaemonRequestHandling:
    """Test daemon request routing with mocked LLM."""

    @pytest.fixture
    def daemon(self) -> AishDaemon:
        config = AishConfig()
        return AishDaemon(config)

    @pytest.mark.asyncio
    async def test_reload_config(self, daemon: AishDaemon) -> None:
        result = await daemon.handle_request({"type": "reload_config"})
        assert result["type"] == "reload_config"

    @pytest.mark.asyncio
    async def test_unknown_type(self, daemon: AishDaemon) -> None:
        result = await daemon.handle_request({"type": "invalid"})
        assert result["type"] == "error"

    @pytest.mark.asyncio
    async def test_empty_nl_prompt(self, daemon: AishDaemon) -> None:
        result = await daemon.handle_request({
            "type": "nl",
            "prompt": "",
            "cwd": "/tmp",
        })
        assert result["command"] == ""

    @pytest.mark.asyncio
    async def test_empty_error_correct(self, daemon: AishDaemon) -> None:
        result = await daemon.handle_request({
            "type": "error_correct",
            "failed_command": "",
            "exit_status": 1,
            "stderr": "",
        })
        assert result["suggestion"] == ""

    @pytest.mark.asyncio
    async def test_empty_history_search(self, daemon: AishDaemon) -> None:
        result = await daemon.handle_request({
            "type": "history_search",
            "query": "",
            "history": [],
        })
        assert result["results"] == []
