"""Tests for ghst CLI commands."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

from ghst.cli import main
from ghst.config import GhstConfig


class TestShellInit:
    """Test `ghst shell-init zsh`."""

    def test_shell_init_zsh_outputs_code(self, capsys: object) -> None:
        with patch("ghst.cli.GhstConfig.load") as mock_load:
            mock_load.return_value = GhstConfig()
            main(["shell-init", "zsh"])
            captured = capsys.readouterr()  # type: ignore[attr-defined]
            assert "__GHST_SRC_DIR" in captured.out
            assert "__GHST_SOCKET" in captured.out
            assert "ghst start" in captured.out

    def test_shell_init_unsupported_shell(self) -> None:
        with pytest.raises(SystemExit):
            main(["shell-init", "bash"])  # type: ignore[arg-type]

    def test_no_command_shows_help(self, capsys: object) -> None:
        with pytest.raises(SystemExit) as exc_info:
            main([])
        assert exc_info.value.code == 0


class TestHelp:
    """Test `ghst help`."""

    def test_help_shows_features(self, capsys: object) -> None:
        main(["help"])
        captured = capsys.readouterr()  # type: ignore[attr-defined]
        assert "Autocomplete" in captured.out
        assert "Ctrl+G" in captured.out

    def test_help_specific_command(self, capsys: object) -> None:
        main(["help", "init"])
        captured = capsys.readouterr()  # type: ignore[attr-defined]
        assert "wizard" in captured.out.lower()

    def test_help_unknown_command(self, capsys: object) -> None:
        main(["help", "nonexistent"])
        captured = capsys.readouterr()  # type: ignore[attr-defined]
        assert "unknown" in captured.out.lower()


class TestSetGetReset:
    """Test config set/get/reset commands."""

    def test_get_known_key(self, capsys: object, tmp_path: Path) -> None:
        config = GhstConfig()
        config.config_path = tmp_path / "config.toml"
        with patch("ghst.cli.GhstConfig.load", return_value=config):
            main(["get", "autocomplete_delay_ms"])
        captured = capsys.readouterr()  # type: ignore[attr-defined]
        assert "200" in captured.out

    def test_get_unknown_key(self, tmp_path: Path) -> None:
        config = GhstConfig()
        config.config_path = tmp_path / "config.toml"
        with (
            patch("ghst.cli.GhstConfig.load", return_value=config),
            pytest.raises(SystemExit),
        ):
            main(["get", "nonexistent_key"])

    def test_set_and_get(self, capsys: object, tmp_path: Path) -> None:
        config = GhstConfig()
        config.config_path = tmp_path / "config.toml"
        with (
            patch("ghst.cli.GhstConfig.load", return_value=config),
            patch("ghst.cli._send_reload"),
        ):
            main(["set", "autocomplete_delay_ms", "300"])
        assert config.ui.autocomplete_delay_ms == 300

    def test_set_boolean(self, tmp_path: Path) -> None:
        config = GhstConfig()
        config.config_path = tmp_path / "config.toml"
        with (
            patch("ghst.cli.GhstConfig.load", return_value=config),
            patch("ghst.cli._send_reload"),
        ):
            main(["set", "error_correction", "false"])
        assert config.ui.error_correction is False

    def test_reset(self, capsys: object, tmp_path: Path) -> None:
        config = GhstConfig()
        config.config_path = tmp_path / "config.toml"
        config.ui.autocomplete_delay_ms = 500
        with (
            patch("ghst.cli.GhstConfig.load", return_value=config),
            patch("ghst.cli._send_reload"),
        ):
            main(["reset", "autocomplete_delay_ms"])
        assert config.ui.autocomplete_delay_ms == 200

    def test_defaults(self, capsys: object, tmp_path: Path) -> None:
        config = GhstConfig()
        config.config_path = tmp_path / "config.toml"
        with patch("ghst.cli.GhstConfig.load", return_value=config):
            main(["defaults"])
        captured = capsys.readouterr()  # type: ignore[attr-defined]
        assert "autocomplete_delay_ms" in captured.out
        assert "model" in captured.out


class TestModel:
    """Test model commands."""

    def test_model_shows_current(self, capsys: object) -> None:
        config = GhstConfig()
        with patch("ghst.cli.GhstConfig.load", return_value=config):
            main(["model"])
        captured = capsys.readouterr()  # type: ignore[attr-defined]
        assert "gpt-4o" in captured.out

    def test_model_set(self, tmp_path: Path) -> None:
        config = GhstConfig()
        config.config_path = tmp_path / "config.toml"
        with (
            patch("ghst.cli.GhstConfig.load", return_value=config),
            patch("ghst.cli._send_reload"),
        ):
            main(["model", "set", "claude-sonnet-4-5"])
        assert config.provider.model == "claude-sonnet-4-5"
        assert config.provider.autocomplete_model == "claude-sonnet-4-5"

    def test_model_set_autocomplete_only(self, tmp_path: Path) -> None:
        config = GhstConfig()
        config.config_path = tmp_path / "config.toml"
        with (
            patch("ghst.cli.GhstConfig.load", return_value=config),
            patch("ghst.cli._send_reload"),
        ):
            main(["model", "set", "--autocomplete", "gpt-4o-mini"])
        assert config.provider.autocomplete_model == "gpt-4o-mini"
        assert config.provider.model == "gpt-4o"  # unchanged


class TestProvider:
    """Test provider commands."""

    def test_provider_shows_current(self, capsys: object) -> None:
        config = GhstConfig()
        with patch("ghst.cli.GhstConfig.load", return_value=config):
            main(["provider"])
        captured = capsys.readouterr()  # type: ignore[attr-defined]
        assert "openai" in captured.out


class TestConfigWriteToml:
    """Test config TOML writing."""

    def test_write_and_reload(self, tmp_path: Path) -> None:
        config = GhstConfig()
        config.provider.name = "anthropic"
        config.provider.api_key = "sk-test"
        config.provider.model = "claude-sonnet-4-5"
        config_path = tmp_path / "config.toml"
        config.write_toml(config_path)

        # Reload and verify
        loaded = GhstConfig.load(config_path)
        assert loaded.provider.name == "anthropic"
        assert loaded.provider.api_key == "sk-test"
        assert loaded.provider.model == "claude-sonnet-4-5"

    def test_write_with_non_default_ui(self, tmp_path: Path) -> None:
        config = GhstConfig()
        config.ui.autocomplete_delay_ms = 500
        config.ui.error_correction = False
        config_path = tmp_path / "config.toml"
        config.write_toml(config_path)

        loaded = GhstConfig.load(config_path)
        assert loaded.ui.autocomplete_delay_ms == 500
        assert loaded.ui.error_correction is False
