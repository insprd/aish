"""Configuration parsing for ghst.

Loads settings from ~/.config/ghst/config.toml with env var overrides.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, ClassVar

try:
    import tomllib  # type: ignore[import-not-found]
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore[import-not-found,no-redef]


def _config_dir() -> Path:
    """Return the ghst config directory (~/.config/ghst)."""
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = Path(xdg) if xdg else Path.home() / ".config"
    return base / "ghst"


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
    autocomplete_delay_ms: int = 100
    autocomplete_delay_short_ms: int = 50
    autocomplete_delay_threshold: int = 8
    autocomplete_min_chars: int = 2
    nl_hotkey: str = "^G"
    history_search_hotkey: str = "^R"
    cheat_sheet_hotkey: str = "^_"
    ghost_color: str = ""
    accent_color: str = ""
    success_color: str = ""
    warning_color: str = ""
    error_color: str = ""
    history_search_limit: int = 500
    error_correction: bool = True
    proactive_suggestions: bool = True
    proactive_output_lines: int = 50
    proactive_capture_blocklist: list[str] = field(
        default_factory=lambda: list(DEFAULT_CAPTURE_BLOCKLIST)
    )


@dataclass
class GhstConfig:
    provider: ProviderConfig = field(default_factory=ProviderConfig)
    ui: UIConfig = field(default_factory=UIConfig)
    config_path: Path = field(default_factory=_default_config_path)

    @classmethod
    def load(cls, path: Path | None = None) -> GhstConfig:
        """Load config from TOML file with env var overrides."""
        config_path = path or _default_config_path()
        raw: dict[str, Any] = {}

        if config_path.exists():
            raw = tomllib.loads(config_path.read_text(encoding="utf-8"))

        return cls._from_dict(raw, config_path)

    @classmethod
    def _from_dict(cls, raw: dict[str, Any], config_path: Path) -> GhstConfig:
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
        env_key = os.environ.get("GHST_API_KEY")
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
            ghost_color=ui_raw.get("ghost_color", ""),
            accent_color=ui_raw.get("accent_color", ""),
            success_color=ui_raw.get("success_color", ""),
            warning_color=ui_raw.get("warning_color", ""),
            error_color=ui_raw.get("error_color", ""),
            history_search_limit=ui_raw.get("history_search_limit", 500),
            error_correction=ui_raw.get("error_correction", True),
            proactive_suggestions=ui_raw.get("proactive_suggestions", True),
            proactive_output_lines=ui_raw.get("proactive_output_lines", 50),
            proactive_capture_blocklist=ui_raw.get(
                "proactive_capture_blocklist", list(DEFAULT_CAPTURE_BLOCKLIST)
            ),
        )

        return cls(provider=provider, ui=ui, config_path=config_path)

    # Map of flat key names to (section, field) for set/get/reset
    FLAT_KEYS: ClassVar[dict[str, tuple[str, str]]] = {
        "provider": ("provider", "name"),
        "api_key": ("provider", "api_key"),
        "api_base_url": ("provider", "api_base_url"),
        "model": ("provider", "model"),
        "autocomplete_model": ("provider", "autocomplete_model"),
        "autocomplete_delay_ms": ("ui", "autocomplete_delay_ms"),
        "autocomplete_delay_short_ms": ("ui", "autocomplete_delay_short_ms"),
        "autocomplete_delay_threshold": ("ui", "autocomplete_delay_threshold"),
        "autocomplete_min_chars": ("ui", "autocomplete_min_chars"),
        "nl_hotkey": ("ui", "nl_hotkey"),
        "history_search_hotkey": ("ui", "history_search_hotkey"),
        "cheat_sheet_hotkey": ("ui", "cheat_sheet_hotkey"),
        "ghost_color": ("ui", "ghost_color"),
        "accent_color": ("ui", "accent_color"),
        "success_color": ("ui", "success_color"),
        "warning_color": ("ui", "warning_color"),
        "error_color": ("ui", "error_color"),
        "history_search_limit": ("ui", "history_search_limit"),
        "error_correction": ("ui", "error_correction"),
        "proactive_suggestions": ("ui", "proactive_suggestions"),
        "proactive_output_lines": ("ui", "proactive_output_lines"),
    }

    def get_flat(self, key: str) -> Any:
        """Get a config value by flat key name."""
        if key not in self.FLAT_KEYS:
            return None
        section, field = self.FLAT_KEYS[key]
        if section == "provider":
            return getattr(self.provider, field, None)
        return getattr(self.ui, field, None)

    def get_default(self, key: str) -> Any:
        """Get the default value for a flat key."""
        if key not in self.FLAT_KEYS:
            return None
        section, field = self.FLAT_KEYS[key]
        if section == "provider":
            return getattr(ProviderConfig(), field, None)
        return getattr(UIConfig(), field, None)

    def _toml_escape(self, s: str) -> str:
        """Escape a string for TOML basic string value."""
        s = s.replace('\\', '\\\\')
        s = s.replace('"', '\\"')
        # Strip any control characters that would be invalid in TOML
        import re
        s = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', s)
        s = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', s)
        return s

    def write_toml(self, path: Path | None = None) -> None:
        """Write current config to a TOML file."""
        target = path or self.config_path
        target.parent.mkdir(parents=True, exist_ok=True)
        esc = self._toml_escape

        lines = ['[provider]']
        lines.append(f'name = "{esc(self.provider.name)}"')
        if self.provider.api_key:
            lines.append(f'api_key = "{esc(self.provider.api_key)}"')
        if self.provider.api_base_url:
            lines.append(f'api_base_url = "{esc(self.provider.api_base_url)}"')
        lines.append(f'model = "{esc(self.provider.model)}"')
        if self.provider.autocomplete_model:
            lines.append(f'autocomplete_model = "{esc(self.provider.autocomplete_model)}"')

        lines.append('')
        lines.append('[ui]')
        defaults = UIConfig()
        if self.ui.autocomplete_delay_ms != defaults.autocomplete_delay_ms:
            lines.append(f'autocomplete_delay_ms = {self.ui.autocomplete_delay_ms}')
        if self.ui.autocomplete_delay_short_ms != defaults.autocomplete_delay_short_ms:
            lines.append(
                f'autocomplete_delay_short_ms = {self.ui.autocomplete_delay_short_ms}'
            )
        if self.ui.autocomplete_delay_threshold != defaults.autocomplete_delay_threshold:
            lines.append(
                f'autocomplete_delay_threshold = {self.ui.autocomplete_delay_threshold}'
            )
        if self.ui.autocomplete_min_chars != defaults.autocomplete_min_chars:
            lines.append(f'autocomplete_min_chars = {self.ui.autocomplete_min_chars}')
        if self.ui.nl_hotkey != defaults.nl_hotkey:
            lines.append(f'nl_hotkey = "{esc(self.ui.nl_hotkey)}"')
        if self.ui.history_search_hotkey != defaults.history_search_hotkey:
            lines.append(f'history_search_hotkey = "{esc(self.ui.history_search_hotkey)}"')
        if self.ui.error_correction != defaults.error_correction:
            v = "true" if self.ui.error_correction else "false"
            lines.append(f'error_correction = {v}')
        if self.ui.proactive_suggestions != defaults.proactive_suggestions:
            v = "true" if self.ui.proactive_suggestions else "false"
            lines.append(f'proactive_suggestions = {v}')
        if self.ui.proactive_output_lines != defaults.proactive_output_lines:
            lines.append(f'proactive_output_lines = {self.ui.proactive_output_lines}')
        if self.ui.ghost_color:
            lines.append(f'ghost_color = "{esc(self.ui.ghost_color)}"')
        if self.ui.accent_color:
            lines.append(f'accent_color = "{esc(self.ui.accent_color)}"')
        if self.ui.success_color:
            lines.append(f'success_color = "{esc(self.ui.success_color)}"')
        if self.ui.warning_color:
            lines.append(f'warning_color = "{esc(self.ui.warning_color)}"')
        if self.ui.error_color:
            lines.append(f'error_color = "{esc(self.ui.error_color)}"')
        if self.ui.history_search_limit != defaults.history_search_limit:
            lines.append(f'history_search_limit = {self.ui.history_search_limit}')

        lines.append('')
        target.write_text('\n'.join(lines), encoding='utf-8')

    def set_value(self, key: str, value: str) -> bool:
        """Set a config value by flat key and save to disk.

        Returns True if successful, False if key not found.
        """
        if key not in self.FLAT_KEYS:
            return False
        section, field_name = self.FLAT_KEYS[key]

        obj = self.provider if section == "provider" else self.ui

        current = getattr(obj, field_name)
        # Type coercion
        if isinstance(current, bool):
            value_typed: Any = value.lower() in ("true", "1", "yes", "on")
        elif isinstance(current, int):
            value_typed = int(value)
        else:
            value_typed = value

        setattr(obj, field_name, value_typed)
        self.write_toml()
        return True

    def reset_value(self, key: str) -> bool:
        """Reset a config value to its default and save to disk."""
        default = self.get_default(key)
        if default is None and key not in self.FLAT_KEYS:
            return False
        section, field_name = self.FLAT_KEYS[key]
        if section == "provider":
            setattr(self.provider, field_name, default)
        else:
            setattr(self.ui, field_name, default)
        self.write_toml()
        return True

    def get_socket_path(self) -> Path:
        """Return the daemon socket path."""
        runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
        if runtime_dir:
            return Path(runtime_dir) / "ghst.sock"
        return Path(f"/tmp/ghst-{os.getuid()}.sock")

    def get_pid_path(self) -> Path:
        """Return the daemon PID file path."""
        runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
        if runtime_dir:
            return Path(runtime_dir) / "ghst.pid"
        return Path(f"/tmp/ghst-{os.getuid()}.pid")
