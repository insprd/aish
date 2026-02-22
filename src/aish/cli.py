"""CLI entry point for aish."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
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
    if pid_path.exists():
        try:
            pid = int(pid_path.read_text().strip())
            os.kill(pid, 0)
            running = True
        except (ProcessLookupError, ValueError):
            pass

    if running:
        print(f"  daemon:     running (pid {pid})")
    else:
        print("  daemon:     not running")

    print(f"  provider:   {config.provider.name} ({config.provider.effective_autocomplete_model})")
    print(f"  config:     {config.config_path}")
    print(f"  socket:     {config.get_socket_path()}")


def main(argv: list[str] | None = None) -> None:
    """Main CLI entry point."""
    parser = argparse.ArgumentParser(
        prog="aish",
        description="AI-powered shell plugin",
    )
    subparsers = parser.add_subparsers(dest="command")

    # shell-init
    sp_init = subparsers.add_parser("shell-init", help="Output shell integration code")
    sp_init.add_argument("shell", choices=["zsh"], help="Shell type")
    sp_init.set_defaults(func=_cmd_shell_init)

    # start
    sp_start = subparsers.add_parser("start", help="Start the daemon")
    sp_start.add_argument("--quiet", "-q", action="store_true", help="Suppress output")
    sp_start.set_defaults(func=_cmd_start)

    # stop
    sp_stop = subparsers.add_parser("stop", help="Stop the daemon")
    sp_stop.set_defaults(func=_cmd_stop)

    # status
    sp_status = subparsers.add_parser("status", help="Show daemon status")
    sp_status.set_defaults(func=_cmd_status)

    args = parser.parse_args(argv)

    if not args.command:
        parser.print_help()
        sys.exit(1)

    args.func(args)
