"""Tests for aish CLI commands."""

from __future__ import annotations

from unittest.mock import patch

from aish.cli import main


class TestShellInit:
    """Test `aish shell-init zsh`."""

    def test_shell_init_zsh_outputs_code(self, capsys: object) -> None:
        with patch("aish.cli.AishConfig.load") as mock_load:
            from aish.config import AishConfig
            mock_load.return_value = AishConfig()
            main(["shell-init", "zsh"])
            captured = capsys.readouterr()  # type: ignore[attr-defined]
            assert "__AISH_SRC_DIR" in captured.out
            assert "__AISH_SOCKET" in captured.out
            assert "aish start" in captured.out

    def test_shell_init_unsupported_shell(self) -> None:
        import pytest
        with pytest.raises(SystemExit):
            main(["shell-init", "bash"])  # type: ignore[arg-type]

    def test_no_command_shows_help(self) -> None:
        import pytest
        with pytest.raises(SystemExit):
            main([])
