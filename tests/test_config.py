"""Tests for aish config parsing."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from aish.config import AishConfig, ProviderConfig


class TestDefaults:
    """Test that defaults are sensible when no config file exists."""

    def test_default_provider(self) -> None:
        config = AishConfig()
        assert config.provider.name == "openai"
        assert config.provider.model == "gpt-4o"

    def test_default_autocomplete_model_falls_back(self) -> None:
        config = AishConfig()
        assert config.provider.autocomplete_model == ""
        assert config.provider.effective_autocomplete_model == "gpt-4o"

    def test_explicit_autocomplete_model(self) -> None:
        provider = ProviderConfig(autocomplete_model="gpt-4o-mini")
        assert provider.effective_autocomplete_model == "gpt-4o-mini"

    def test_default_ui(self) -> None:
        config = AishConfig()
        assert config.ui.autocomplete_delay_ms == 200
        assert config.ui.autocomplete_delay_short_ms == 100
        assert config.ui.autocomplete_delay_threshold == 8
        assert config.ui.autocomplete_min_chars == 3
        assert config.ui.nl_hotkey == "^G"
        assert config.ui.history_search_hotkey == "^R"
        assert config.ui.error_correction is True
        assert config.ui.proactive_suggestions is True
        assert config.ui.proactive_output_lines == 50

    def test_default_blocklist(self) -> None:
        config = AishConfig()
        assert "vim" in config.ui.proactive_capture_blocklist
        assert "ssh" in config.ui.proactive_capture_blocklist
        assert "fzf" in config.ui.proactive_capture_blocklist


class TestApiBaseUrl:
    """Test API base URL defaults per provider."""

    def test_openai_default(self) -> None:
        provider = ProviderConfig(name="openai")
        assert provider.effective_api_base_url == "https://api.openai.com/v1"

    def test_anthropic_default(self) -> None:
        provider = ProviderConfig(name="anthropic")
        assert provider.effective_api_base_url == "https://api.anthropic.com"

    def test_custom_base_url(self) -> None:
        provider = ProviderConfig(name="openai", api_base_url="http://localhost:11434/v1")
        assert provider.effective_api_base_url == "http://localhost:11434/v1"


class TestLoadFromFile:
    """Test loading config from a TOML file."""

    def test_load_minimal(self, tmp_path: Path) -> None:
        config_file = tmp_path / "config.toml"
        config_file.write_text("""
[provider]
name = "anthropic"
api_key = "sk-ant-test"
model = "claude-sonnet-4-5"
""")
        config = AishConfig.load(config_file)
        assert config.provider.name == "anthropic"
        assert config.provider.api_key == "sk-ant-test"
        assert config.provider.model == "claude-sonnet-4-5"
        # UI defaults preserved
        assert config.ui.autocomplete_delay_ms == 200

    def test_load_full(self, tmp_path: Path) -> None:
        config_file = tmp_path / "config.toml"
        config_file.write_text("""
[provider]
name = "openai"
api_key = "sk-test"
model = "gpt-4o"
autocomplete_model = "gpt-4o-mini"

[ui]
autocomplete_delay_ms = 300
autocomplete_min_chars = 5
error_correction = false
proactive_suggestions = false
""")
        config = AishConfig.load(config_file)
        assert config.provider.autocomplete_model == "gpt-4o-mini"
        assert config.provider.effective_autocomplete_model == "gpt-4o-mini"
        assert config.ui.autocomplete_delay_ms == 300
        assert config.ui.autocomplete_min_chars == 5
        assert config.ui.error_correction is False
        assert config.ui.proactive_suggestions is False

    def test_load_nonexistent(self, tmp_path: Path) -> None:
        config = AishConfig.load(tmp_path / "nonexistent.toml")
        # Should return defaults
        assert config.provider.name == "openai"
        assert config.ui.autocomplete_delay_ms == 200


class TestEnvVarOverride:
    """Test AISH_API_KEY environment variable override."""

    def test_env_var_overrides_config_file(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        config_file = tmp_path / "config.toml"
        config_file.write_text("""
[provider]
api_key = "from-file"
""")
        monkeypatch.setenv("AISH_API_KEY", "from-env")
        config = AishConfig.load(config_file)
        assert config.provider.api_key == "from-env"

    def test_env_var_when_no_file(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("AISH_API_KEY", "from-env")
        config = AishConfig.load(tmp_path / "nonexistent.toml")
        assert config.provider.api_key == "from-env"

    def test_no_env_var_uses_file(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        config_file = tmp_path / "config.toml"
        config_file.write_text("""
[provider]
api_key = "from-file"
""")
        monkeypatch.delenv("AISH_API_KEY", raising=False)
        config = AishConfig.load(config_file)
        assert config.provider.api_key == "from-file"


class TestSocketPath:
    """Test socket and PID path resolution."""

    def test_xdg_runtime_dir(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("XDG_RUNTIME_DIR", "/run/user/1000")
        config = AishConfig()
        assert config.get_socket_path() == Path("/run/user/1000/aish.sock")
        assert config.get_pid_path() == Path("/run/user/1000/aish.pid")

    def test_fallback_tmp(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv("XDG_RUNTIME_DIR", raising=False)
        config = AishConfig()
        uid = os.getuid()
        assert config.get_socket_path() == Path(f"/tmp/aish-{uid}.sock")
        assert config.get_pid_path() == Path(f"/tmp/aish-{uid}.pid")
