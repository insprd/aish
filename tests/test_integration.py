"""Integration test for daemon socket communication."""

from __future__ import annotations

import asyncio
import contextlib
import json
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

from ghst.config import GhstConfig
from ghst.daemon import GhstDaemon


class TestDaemonIntegration:
    """Test the daemon's socket server with real asyncio connections."""

    @pytest.fixture
    def config(self, tmp_path: Path) -> GhstConfig:
        """Create a config pointing to a temp socket."""
        config = GhstConfig()
        # Use /tmp for socket to avoid AF_UNIX path length limit on macOS
        import tempfile
        sock_dir = Path(tempfile.mkdtemp(prefix="ghst-test-"))
        config._test_socket_path = sock_dir / "test.sock"
        config._test_pid_path = sock_dir / "test.pid"
        return config

    @pytest.fixture
    def daemon(self, config: GhstConfig) -> GhstDaemon:
        d = GhstDaemon(config)
        # Override socket/pid paths
        d.config.get_socket_path = lambda: config._test_socket_path  # type: ignore[attr-defined]
        d.config.get_pid_path = lambda: config._test_pid_path  # type: ignore[attr-defined]
        return d

    @pytest.mark.asyncio
    async def test_daemon_handles_complete_request(self, daemon: GhstDaemon) -> None:
        """Test that the daemon can handle a complete request via handle_request."""
        mock_return = "tus --short"
        with patch.object(
            daemon.llm, "complete", new_callable=AsyncMock, return_value=mock_return
        ):
            result = await daemon.handle_request({
                "type": "complete",
                "buffer": "git sta",
                "cwd": "/tmp",
                "shell": "zsh",
                "history": [],
                "request_id": "test-1",
            })
            assert result["type"] == "complete"
            # LLM returned a word continuation, no space needed
            assert result["suggestion"] == "tus --short"
            assert result["request_id"] == "test-1"

    @pytest.mark.asyncio
    async def test_daemon_handles_nl_request(self, daemon: GhstDaemon) -> None:
        mock_return = "find . -name '*.py'"
        with patch.object(
            daemon.llm, "complete_with_retry",
            new_callable=AsyncMock, return_value=mock_return,
        ):
            result = await daemon.handle_request({
                "type": "nl",
                "prompt": "find python files",
                "cwd": "/tmp",
                "shell": "zsh",
            })
            assert result["type"] == "nl"
            assert result["command"] == "find . -name '*.py'"

    @pytest.mark.asyncio
    async def test_daemon_handles_error_correct(self, daemon: GhstDaemon) -> None:
        mock_return = "git push origin main"
        with patch.object(
            daemon.llm, "complete",
            new_callable=AsyncMock, return_value=mock_return,
        ):
            result = await daemon.handle_request({
                "type": "error_correct",
                "failed_command": "git pussh origin main",
                "exit_status": 1,
                "stderr": "git: 'pussh' is not a git command.",
                "cwd": "/tmp",
                "shell": "zsh",
            })
            assert result["type"] == "error_correct"
            assert result["suggestion"] == "git push origin main"

    @pytest.mark.asyncio
    async def test_daemon_handles_proactive(self, daemon: GhstDaemon) -> None:
        with patch.object(
            daemon.llm, "complete",
            new_callable=AsyncMock, return_value="npm audit fix",
        ):
            result = await daemon.handle_request({
                "type": "complete",
                "buffer": "",
                "cwd": "/tmp",
                "shell": "zsh",
                "history": [],
                "exit_status": 0,
                "last_command": "npm install",
                "last_output": "found 3 vulnerabilities\nrun `npm audit fix`",
                "request_id": "pro-1",
            })
            assert result["type"] == "complete"
            assert result["suggestion"] == "npm audit fix"

    @pytest.mark.asyncio
    async def test_daemon_socket_server(self, daemon: GhstDaemon) -> None:
        """Test actual socket communication."""
        socket_path = daemon.config.get_socket_path()

        # Start server in background
        server_task = asyncio.create_task(daemon.start())

        # Wait for socket to be ready
        for _ in range(50):
            if socket_path.exists():
                break
            await asyncio.sleep(0.01)

        try:
            # Connect and send a request
            reader, writer = await asyncio.open_unix_connection(str(socket_path))

            request = {"type": "reload_config"}
            writer.write(json.dumps(request).encode() + b"\n")
            await writer.drain()

            response_line = await asyncio.wait_for(reader.readline(), timeout=5.0)
            response = json.loads(response_line)

            assert response["type"] == "reload_config"

            writer.close()
            await writer.wait_closed()
        finally:
            await daemon.stop()
            server_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await server_task
