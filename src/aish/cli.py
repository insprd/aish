"""CLI entry point for aish."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

from aish.config import AishConfig


def _get_src_dir() -> str:
    """Return the aish Python source directory for auto-reload detection."""
    return str(Path(__file__).resolve().parent)


def _shell_init_zsh(config: AishConfig) -> None:
    """Output zsh integration code for eval."""
    src_dir = _get_src_dir()
    shell_dir = str(Path(__file__).resolve().parent.parent.parent / "shell" / "zsh")
    socket_path = config.get_socket_path()

    print(f'''# aish — AI-powered shell plugin
# Add to .zshrc: eval "$(aish shell-init zsh)"

export __AISH_SRC_DIR="{src_dir}"
export __AISH_SHELL_DIR="{shell_dir}"
export __AISH_SOCKET="{socket_path}"

# Auto-start daemon if not running
if [[ ! -S "$__AISH_SOCKET" ]]; then
    aish start --quiet &>/dev/null &!
fi

# Source shell integration scripts
for f in "$__AISH_SHELL_DIR"/*.zsh; do
    [[ -f "$f" ]] && source "$f"
done
''')


def _cmd_shell_init(args: argparse.Namespace) -> None:
    """Handle `aish shell-init <shell>`."""
    config = AishConfig.load()
    shell = args.shell
    if shell != "zsh":
        print(f"aish: shell '{shell}' is not yet supported (only zsh)", file=sys.stderr)
        sys.exit(1)
    _shell_init_zsh(config)


def _cmd_start(args: argparse.Namespace) -> None:
    """Handle `aish start`."""
    config = AishConfig.load()
    pid_path = config.get_pid_path()
    socket_path = config.get_socket_path()

    # Check if already running
    if pid_path.exists():
        try:
            pid = int(pid_path.read_text().strip())
            os.kill(pid, 0)  # Check if process exists
            if not getattr(args, "quiet", False):
                print(f"aish: daemon already running (pid {pid})")
            return
        except (ProcessLookupError, ValueError):
            # Stale PID file
            pid_path.unlink(missing_ok=True)
            socket_path.unlink(missing_ok=True)

    # Start daemon as a background process
    daemon_cmd = [sys.executable, "-m", "aish.daemon"]
    proc = subprocess.Popen(
        daemon_cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    pid_path.write_text(str(proc.pid))

    if not getattr(args, "quiet", False):
        print(f"aish: daemon started (pid {proc.pid})")


def _cmd_stop(args: argparse.Namespace) -> None:
    """Handle `aish stop`."""
    config = AishConfig.load()
    pid_path = config.get_pid_path()
    socket_path = config.get_socket_path()

    if not pid_path.exists():
        print("aish: daemon not running")
        return

    try:
        pid = int(pid_path.read_text().strip())
        os.kill(pid, signal.SIGTERM)
        print(f"aish: daemon stopped (pid {pid})")
    except ProcessLookupError:
        print("aish: daemon not running (stale pid file)")
    except ValueError:
        print("aish: invalid pid file")

    pid_path.unlink(missing_ok=True)
    socket_path.unlink(missing_ok=True)


def _cmd_status(args: argparse.Namespace) -> None:
    """Handle `aish status`."""
    config = AishConfig.load()
    pid_path = config.get_pid_path()

    running = False
    pid = None
    uptime_str = ""
    if pid_path.exists():
        try:
            pid = int(pid_path.read_text().strip())
            os.kill(pid, 0)
            running = True
            # Calculate uptime from PID file mtime
            mtime = pid_path.stat().st_mtime
            uptime_secs = time.time() - mtime
            if uptime_secs < 60:
                uptime_str = f"{int(uptime_secs)}s"
            elif uptime_secs < 3600:
                uptime_str = f"{int(uptime_secs / 60)}m"
            else:
                uptime_str = f"{uptime_secs / 3600:.1f}h"
        except (ProcessLookupError, ValueError):
            pass

    if running:
        print(f"  daemon:     running (pid {pid}, uptime {uptime_str})")
    else:
        print("  daemon:     not running")

    print(
        f"  provider:   {config.provider.name} "
        f"({config.provider.effective_autocomplete_model})"
    )
    print(f"  config:     {config.config_path}")
    print(f"  socket:     {config.get_socket_path()}")

    # Query daemon for health info if running
    if running:
        health = _query_daemon_health(config)
        if health:
            _print_health(health)


def _query_daemon_health(config: AishConfig) -> dict | None:
    """Query the daemon for connection health info via reload_config."""
    # We reuse the socket to get a simple ping; full health reporting
    # would require a dedicated status endpoint in the daemon
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect(str(config.get_socket_path()))
        sock.sendall(b'{"type":"reload_config"}\n')
        data = sock.recv(4096)
        sock.close()
        if data:
            return json.loads(data.decode())
    except (OSError, json.JSONDecodeError):
        pass
    return None


def _print_health(health: dict) -> None:
    """Print connection health information."""
    if health.get("ok"):
        print("  connection: ok")


# ── Init wizard ──────────────────────────────────────────────────────────────

def _cmd_init(args: argparse.Namespace) -> None:
    """Handle `aish init` — interactive setup wizard."""
    print("  aish — AI-powered shell plugin\n")

    # Step 1: Detect shell
    shell = os.environ.get("SHELL", "").rsplit("/", 1)[-1] or "zsh"
    print(f"  Detected shell: {shell}")
    if shell != "zsh":
        print("  ⚠ Only zsh is supported currently. Proceeding with zsh.")
        shell = "zsh"

    print(f'\n  Add this to your ~/.{shell}rc:\n')
    print(f'    eval "$(aish shell-init {shell})"')
    print(f'\n  Then restart your shell or run: exec {shell}\n')

    # Step 2: Configure provider
    print("  Choose your LLM provider:")
    print("    1) OpenAI (default)")
    print("    2) Anthropic")
    choice = input("\n  > ").strip()
    provider = "anthropic" if choice == "2" else "openai"

    # API key
    default_models = {
        "openai": ("gpt-4o", "gpt-4o-mini"),
        "anthropic": ("claude-sonnet-4-5", "claude-haiku-4-5"),
    }

    api_key = ""
    env_key = os.environ.get("AISH_API_KEY", "")
    if env_key:
        print("\n  API key found in AISH_API_KEY environment variable ✓")
        api_key = ""  # Don't store in config if env var is set
    else:
        api_key = getpass.getpass("\n  API key: ")

    # Models
    default_model, default_autocomplete = default_models[provider]
    model = input(f"  Model for commands [{default_model}]: ").strip()
    model = model or default_model
    ac_model = input(f"  Model for autocomplete [{default_autocomplete}]: ").strip()
    ac_model = ac_model or default_autocomplete

    # Write config
    config = AishConfig()
    config.provider.name = provider
    config.provider.api_key = api_key
    config.provider.model = model
    config.provider.autocomplete_model = ac_model
    config.write_toml()

    print(f"\n  ✓ Config written to {config.config_path}")

    # Step 3: Verify connection
    print("\n  Verifying connection...")

    # Start daemon
    _cmd_start(argparse.Namespace(quiet=True))
    time.sleep(1)  # Give daemon time to start

    # Test connection
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect(str(config.get_socket_path()))
        sock.sendall(b'{"type":"reload_config"}\n')
        data = sock.recv(4096)
        sock.close()
        result = json.loads(data.decode())
        if result.get("ok"):
            print("  ✓ Daemon started")
            print(f"  ✓ Connected to {provider} ({ac_model})")
        else:
            print("  ⚠ Daemon started but config reload failed")
    except OSError:
        print("  ⚠ Could not connect to daemon — run 'aish start' manually")

    print("\n  You're all set! Open a new shell and start typing.\n")
    print("    → Autocomplete appears as ghost text (accept with Tab or →)")
    print("    → Press Ctrl+G for natural language command mode")
    print("    → Press Ctrl+R to search history in plain English")
    print("    → Run `aish status` to check daemon health")
    print("    → Run `aish help` for all commands\n")


# ── Config commands ──────────────────────────────────────────────────────────

def _cmd_config(args: argparse.Namespace) -> None:
    """Handle `aish config` — open config in $EDITOR."""
    config = AishConfig.load()
    config_path = config.config_path

    if not config_path.exists():
        config_path.parent.mkdir(parents=True, exist_ok=True)
        # Copy default config
        default = Path(__file__).resolve().parent.parent.parent / "config" / "default.toml"
        if default.exists():
            config_path.write_text(default.read_text())
        else:
            config.write_toml()

    editor = os.environ.get("EDITOR", "vi")
    subprocess.run([editor, str(config_path)])


def _send_reload(config: AishConfig) -> None:
    """Send reload_config to daemon after config changes."""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect(str(config.get_socket_path()))
        sock.sendall(b'{"type":"reload_config"}\n')
        sock.recv(4096)
        sock.close()
    except OSError:
        pass  # Daemon not running; changes take effect on next start


def _cmd_set(args: argparse.Namespace) -> None:
    """Handle `aish set <key> <value>`."""
    config = AishConfig.load()
    key = args.key
    value = args.value

    if config.set_value(key, value):
        print(f"  ✓ {key} → {value}")
        _send_reload(config)
        if "hotkey" in key:
            print("  ⚠ Restart your shell for hotkey changes to take effect")
    else:
        print(f"  aish: unknown config key '{key}'", file=sys.stderr)
        print("  Run `aish defaults` to see available keys", file=sys.stderr)
        sys.exit(1)


def _cmd_get(args: argparse.Namespace) -> None:
    """Handle `aish get <key>`."""
    config = AishConfig.load()
    key = args.key
    value = config.get_flat(key)
    default = config.get_default(key)

    if value is None and key not in AishConfig.FLAT_KEYS:
        print(f"  aish: unknown config key '{key}'", file=sys.stderr)
        sys.exit(1)

    if value == default:
        print(f"  {key} = {value} (default)")
    else:
        print(f"  {key} = {value} (default: {default})")


def _cmd_reset(args: argparse.Namespace) -> None:
    """Handle `aish reset <key>`."""
    config = AishConfig.load()
    key = args.key

    if config.reset_value(key):
        default = config.get_default(key)
        print(f"  ✓ {key} → {default} (default)")
        _send_reload(config)
    else:
        print(f"  aish: unknown config key '{key}'", file=sys.stderr)
        sys.exit(1)


def _cmd_defaults(args: argparse.Namespace) -> None:
    """Handle `aish defaults`."""
    config = AishConfig.load()
    for key in AishConfig.FLAT_KEYS:
        value = config.get_flat(key)
        default = config.get_default(key)
        # Mask API key
        display = value
        if key == "api_key" and value:
            display = value[:4] + "..." + value[-4:] if len(str(value)) > 8 else "****"
        pad = " " * (28 - len(key))
        if value == default:
            print(f"  {key}{pad}= {display}")
        else:
            print(f"  {key}{pad}= {display} (default: {default})")


# ── Model commands ───────────────────────────────────────────────────────────

def _cmd_model(args: argparse.Namespace) -> None:
    """Handle `aish model`."""
    config = AishConfig.load()
    ac = config.provider.effective_autocomplete_model
    nl = config.provider.model
    name = config.provider.name
    print(f"  autocomplete: {ac} ({name})")
    print(f"  nl-commands:  {nl} ({name})")


def _cmd_model_set(args: argparse.Namespace) -> None:
    """Handle `aish model set <model>`."""
    config = AishConfig.load()
    model = args.model

    if args.autocomplete:
        config.provider.autocomplete_model = model
        config.write_toml()
        print(f"  ✓ autocomplete model → {model}")
    elif args.nl:
        config.provider.model = model
        config.write_toml()
        print(f"  ✓ nl-commands model → {model}")
    else:
        # Set both
        config.provider.model = model
        config.provider.autocomplete_model = model
        config.write_toml()
        print(f"  ✓ model → {model} (autocomplete + nl-commands)")

    _send_reload(config)


# ── Provider commands ────────────────────────────────────────────────────────

def _cmd_provider(args: argparse.Namespace) -> None:
    """Handle `aish provider`."""
    config = AishConfig.load()
    print(f"  provider: {config.provider.name}")
    print(f"  endpoint: {config.provider.effective_api_base_url}")


def _cmd_provider_set(args: argparse.Namespace) -> None:
    """Handle `aish provider set <name>`."""
    config = AishConfig.load()
    name = args.name

    if name not in ("openai", "anthropic"):
        print(f"  aish: unknown provider '{name}' (use 'openai' or 'anthropic')")
        sys.exit(1)

    config.provider.name = name

    # Prompt for API key if switching providers
    env_key = os.environ.get("AISH_API_KEY", "")
    if not env_key:
        api_key = getpass.getpass("  API key: ")
        config.provider.api_key = api_key

    # Suggest default models
    defaults = {
        "openai": ("gpt-4o", "gpt-4o-mini"),
        "anthropic": ("claude-sonnet-4-5", "claude-haiku-4-5"),
    }
    default_model, default_ac = defaults[name]
    model = input(f"  Model for commands [{default_model}]: ").strip()
    config.provider.model = model or default_model
    ac_model = input(f"  Model for autocomplete [{default_ac}]: ").strip()
    config.provider.autocomplete_model = ac_model or default_ac

    config.write_toml()
    _send_reload(config)
    print(f"  ✓ provider → {name}")


# ── Help command ─────────────────────────────────────────────────────────────

HELP_TEXT = """\
  aish — AI-powered shell plugin

  Features:
    Autocomplete       Ghost text suggestions as you type (Tab/→ to accept)
    NL Commands        Ctrl+G → describe in English → get a command
    Error Correction   Automatic fix suggestions after failed commands
    History Search     Ctrl+R → search history in plain English
    Cheat Sheet        Ctrl+/ → show shortcuts at the prompt

  Commands:
    aish init                 Setup wizard (re-run to reconfigure)
    aish status               Daemon health, provider, models, uptime
    aish model [set]          Show or change models
    aish provider [set]       Show or change LLM provider
    aish set <key> <value>    Change a config value
    aish get <key>            Show a config value
    aish reset <key>          Reset a config key to default
    aish defaults             Show all settings with defaults
    aish config               Edit config file in $EDITOR
    aish start | stop         Manage daemon
    aish help                 This screen

  Run `aish help <command>` for details on any command.
"""

HELP_COMMANDS: dict[str, str] = {
    "init": (
        "  aish init\n\n  Interactive setup wizard. Detects your shell,\n"
        "  prompts for LLM provider and API key, writes config,\n"
        "  and verifies the connection. Safe to re-run."
    ),
    "start": (
        "  aish start [--quiet]\n\n  Start the background daemon.\n"
        "  Auto-starts on first use via shell-init."
    ),
    "stop": "  aish stop\n\n  Stop the background daemon.",
    "status": (
        "  aish status\n\n  Show daemon health: running state, PID,\n"
        "  uptime, provider, models, connection quality."
    ),
    "model": (
        "  aish model\n  aish model set <model>\n"
        "  aish model set --autocomplete <model>\n"
        "  aish model set --nl <model>\n\n"
        "  Show or change models. Without flags, sets both."
    ),
    "provider": (
        "  aish provider\n  aish provider set <name>\n\n"
        "  Show or switch provider (openai, anthropic).\n"
        "  Prompts for API key and models when switching."
    ),
    "set": (
        "  aish set <key> <value>\n\n  Set any config value.\n"
        "  Example: aish set autocomplete_delay_ms 300\n\n"
        "  Run `aish defaults` to see available keys."
    ),
    "get": "  aish get <key>\n\n  Show current and default value of a config key.",
    "reset": "  aish reset <key>\n\n  Reset a config key to its default value.",
    "defaults": "  aish defaults\n\n  Show all config keys with current and default values.",
    "config": "  aish config\n\n  Open ~/.config/aish/config.toml in $EDITOR.",
}


def _cmd_help(args: argparse.Namespace) -> None:
    """Handle `aish help [command]`."""
    command = getattr(args, "help_command", None)
    if command and command in HELP_COMMANDS:
        print(HELP_COMMANDS[command])
    elif command:
        print(f"  aish: unknown command '{command}'")
        print("  Run `aish help` to see all commands.")
    else:
        print(HELP_TEXT)


def main(argv: list[str] | None = None) -> None:
    """Main CLI entry point."""
    parser = argparse.ArgumentParser(
        prog="aish",
        description="AI-powered shell plugin",
    )
    subparsers = parser.add_subparsers(dest="command")

    # init
    sp = subparsers.add_parser("init", help="Interactive setup wizard")
    sp.set_defaults(func=_cmd_init)

    # shell-init
    sp = subparsers.add_parser("shell-init", help="Output shell integration code")
    sp.add_argument("shell", choices=["zsh"], help="Shell type")
    sp.set_defaults(func=_cmd_shell_init)

    # start
    sp = subparsers.add_parser("start", help="Start the daemon")
    sp.add_argument("--quiet", "-q", action="store_true", help="Suppress output")
    sp.set_defaults(func=_cmd_start)

    # stop
    sp = subparsers.add_parser("stop", help="Stop the daemon")
    sp.set_defaults(func=_cmd_stop)

    # status
    sp = subparsers.add_parser("status", help="Show daemon status and health")
    sp.set_defaults(func=_cmd_status)

    # config
    sp = subparsers.add_parser("config", help="Open config file in $EDITOR")
    sp.set_defaults(func=_cmd_config)

    # model
    sp_model = subparsers.add_parser("model", help="Show or change models")
    sp_model.set_defaults(func=_cmd_model)
    model_sub = sp_model.add_subparsers(dest="model_command")
    sp_model_set = model_sub.add_parser("set", help="Set model")
    sp_model_set.add_argument("model", help="Model name")
    sp_model_set.add_argument(
        "--autocomplete", action="store_true", help="Set autocomplete model only"
    )
    sp_model_set.add_argument(
        "--nl", action="store_true", help="Set NL command model only"
    )
    sp_model_set.set_defaults(func=_cmd_model_set)

    # provider
    sp_provider = subparsers.add_parser("provider", help="Show or change provider")
    sp_provider.set_defaults(func=_cmd_provider)
    provider_sub = sp_provider.add_subparsers(dest="provider_command")
    sp_provider_set = provider_sub.add_parser("set", help="Set provider")
    sp_provider_set.add_argument("name", help="Provider name (openai, anthropic)")
    sp_provider_set.set_defaults(func=_cmd_provider_set)

    # set
    sp = subparsers.add_parser("set", help="Set a config value")
    sp.add_argument("key", help="Config key")
    sp.add_argument("value", help="Config value")
    sp.set_defaults(func=_cmd_set)

    # get
    sp = subparsers.add_parser("get", help="Get a config value")
    sp.add_argument("key", help="Config key")
    sp.set_defaults(func=_cmd_get)

    # reset
    sp = subparsers.add_parser("reset", help="Reset a config value to default")
    sp.add_argument("key", help="Config key")
    sp.set_defaults(func=_cmd_reset)

    # defaults
    sp = subparsers.add_parser("defaults", help="Show all settings with defaults")
    sp.set_defaults(func=_cmd_defaults)

    # help
    sp = subparsers.add_parser("help", help="Show help")
    sp.add_argument("help_command", nargs="?", default=None, help="Command to get help for")
    sp.set_defaults(func=_cmd_help)

    args = parser.parse_args(argv)

    if not args.command:
        _cmd_help(argparse.Namespace(help_command=None))
        sys.exit(0)

    args.func(args)
