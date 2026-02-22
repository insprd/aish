"""Configuration parsing for aish.

Loads settings from ~/.config/aish/config.toml with env var overrides.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

if sys.version_info >= (3, 11):
    import tomllib
else:
    try:
        import tomllib
    except ModuleNotFoundError:
        import tomli as tomllib  # type: ignore[no-redef]


def _config_dir() -> Path:
    """Return the aish config directory (~/.config/aish)."""
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = Path(xdg) if xdg else Path.home() / ".config"
    return base / "aish"


def _default_config_path() -> Path:
    return _config_dir() / "config.toml"


def _default_api_base_url(provider: str) -> str:
    if provider == "anthropic":
        return "https://api.anthropic.com"
    return "https://api.openai.com/v1"


@dataclass
class ProviderConfig:
    name: str = "openai"
    api_key: str = ""
    api_base_url: str = ""
    model: str = "gpt-4o"
    autocomplete_model: str = ""

    @property
    def effective_autocomplete_model(self) -> str:
        return self.autocomplete_model or self.model

    @property
    def effective_api_base_url(self) -> str:
        return self.api_base_url or _default_api_base_url(self.name)


DEFAULT_CAPTURE_BLOCKLIST: list[str] = [
    "vim", "nvim", "vi", "nano", "emacs", "pico",
    "less", "more", "most", "bat",
    "top", "htop", "btop", "glances",
    "tmux", "screen",
    "ssh", "mosh",
    "python", "ipython", "node", "irb", "ghci",
    "fzf", "sk",
    "man", "info",
    "watch",
]


@dataclass
class UIConfig:
    autocomplete_delay_ms: int = 200
    autocomplete_delay_short_ms: int = 100
    autocomplete_delay_threshold: int = 8
    autocomplete_min_chars: int = 3
    nl_hotkey: str = "^G"
    history_search_hotkey: str = "^R"
    cheat_sheet_hotkey: str = "^_"
    history_search_limit: int = 500
    error_correction: bool = True
    proactive_suggestions: bool = True
    proactive_output_lines: int = 50
    proactive_capture_blocklist: list[str] = field(
        default_factory=lambda: list(DEFAULT_CAPTURE_BLOCKLIST)
    )


@dataclass
class AishConfig:
    provider: ProviderConfig = field(default_factory=ProviderConfig)
    ui: UIConfig = field(default_factory=UIConfig)
    config_path: Path = field(default_factory=_default_config_path)

    @classmethod
    def load(cls, path: Path | None = None) -> AishConfig:
        """Load config from TOML file with env var overrides."""
        config_path = path or _default_config_path()
        raw: dict[str, Any] = {}

        if config_path.exists():
            raw = tomllib.loads(config_path.read_text(encoding="utf-8"))

        return cls._from_dict(raw, config_path)

    @classmethod
    def _from_dict(cls, raw: dict[str, Any], config_path: Path) -> AishConfig:
        provider_raw = raw.get("provider", {})
        ui_raw = raw.get("ui", {})

        provider = ProviderConfig(
            name=provider_raw.get("name", "openai"),
            api_key=provider_raw.get("api_key", ""),
            api_base_url=provider_raw.get("api_base_url", ""),
            model=provider_raw.get("model", "gpt-4o"),
            autocomplete_model=provider_raw.get("autocomplete_model", ""),
        )

        # Env var override for API key (highest priority)
        env_key = os.environ.get("AISH_API_KEY")
        if env_key:
            provider.api_key = env_key

        ui = UIConfig(
            autocomplete_delay_ms=ui_raw.get("autocomplete_delay_ms", 200),
            autocomplete_delay_short_ms=ui_raw.get("autocomplete_delay_short_ms", 100),
            autocomplete_delay_threshold=ui_raw.get("autocomplete_delay_threshold", 8),
            autocomplete_min_chars=ui_raw.get("autocomplete_min_chars", 3),
            nl_hotkey=ui_raw.get("nl_hotkey", "^G"),
            history_search_hotkey=ui_raw.get("history_search_hotkey", "^R"),
            cheat_sheet_hotkey=ui_raw.get("cheat_sheet_hotkey", "^_"),
            history_search_limit=ui_raw.get("history_search_limit", 500),
            error_correction=ui_raw.get("error_correction", True),
            proactive_suggestions=ui_raw.get("proactive_suggestions", True),
            proactive_output_lines=ui_raw.get("proactive_output_lines", 50),
            proactive_capture_blocklist=ui_raw.get(
                "proactive_capture_blocklist", list(DEFAULT_CAPTURE_BLOCKLIST)
            ),
        )

        return cls(provider=provider, ui=ui, config_path=config_path)

    def get_socket_path(self) -> Path:
        """Return the daemon socket path."""
        runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
        if runtime_dir:
            return Path(runtime_dir) / "aish.sock"
        return Path(f"/tmp/aish-{os.getuid()}.sock")

    def get_pid_path(self) -> Path:
        """Return the daemon PID file path."""
        runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
        if runtime_dir:
            return Path(runtime_dir) / "aish.pid"
        return Path(f"/tmp/aish-{os.getuid()}.pid")
