# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**aish** (AI Shell) is an LLM-powered zsh plugin that provides ghost-text autocomplete, natural language command generation, error correction, and history search — all via a background Python daemon connected to ZLE (Zsh Line Editor) over a Unix domain socket.

## Architecture

### Two-process design

```
zsh (ZLE widgets)  ←──── Unix domain socket ────→  aishd (Python async daemon)
  autocomplete.zsh                                    daemon.py (asyncio)
  nl-command.zsh                                      llm.py (httpx)
  aish.zsh (main)                                     context.py, safety.py, config.py
```

The zsh side sends newline-delimited JSON requests; the daemon responds with completions. The socket lives at `$XDG_RUNTIME_DIR/aish.sock` (fallback: `/tmp/aish-$UID.sock`).

Shell files are **inlined** into the `eval "$(aish shell-init zsh)"` output at init time — they are NOT sourced at runtime. This avoids path resolution issues with non-standard installs (pipx, uv tool, etc.).

### File layout

```
src/aish/
  __init__.py
  __main__.py    – python -m aish entry point
  cli.py         – CLI commands (shell-init, start, stop, status, init, model, provider, etc.)
  config.py      – ~/.config/aish/config.toml parsing, defaults, env var override
  daemon.py      – asyncio socket server, request routing, session buffer, rate limiting, idle timeout
  llm.py         – async LLM client (OpenAI + Anthropic), circuit breaker, caching, prompt caching
  prompts.py     – system/user prompt templates for all request types
  context.py     – cwd/git/env context gathering & caching
  safety.py      – dangerous-command detection, history/output sanitization
  shell/
    aish.zsh           – precmd/preexec hooks, history helper, auto-reload, cheat sheet
    autocomplete.zsh   – ghost text via direct /dev/tty escape codes, zsocket IPC, adaptive debounce
    nl-command.zsh     – Ctrl+G natural-language widget, Ctrl+R history search, Ctrl+Z undo
tests/
  test_config.py, test_prompts.py, test_llm.py, test_daemon.py,
  test_safety.py, test_integration.py
```

### IPC message types

| type | key fields |
|------|-----------|
| `complete` | `buffer`, `cwd`, `shell`, `history`, `exit_status`, `last_command`*, `last_output`* |
| `nl` | `prompt`, `cwd`, `shell` |
| `error_correct` | `failed_command`, `exit_status`, `stderr`, `cwd`, `shell` |
| `history_search` | `query`, `history`, `shell` |
| `reload_config` | (none) |

\* `last_command` and `last_output` are optional fields sent only for proactive suggestions.

### Configuration (`~/.config/aish/config.toml`)

Key sections: `[provider]` (name, api_key, api_base_url, model, autocomplete_model) and `[ui]` (delays, hotkeys, feature toggles). Supports OpenAI and Anthropic.

## Development Commands

Always use `uv` for all Python-related tasks (running scripts, tests, linters, installing packages). Never use bare `pip`, `python`, `pytest`, etc.

```bash
# Create venv and install for development
uv venv && source .venv/bin/activate
uv pip install -e ".[dev]"

# Run tests
uv run pytest

# Run tests with verbose output
uv run pytest -v

# Lint & type-check
uv run ruff check src/
uv run basedpyright src/aish/

# CLI commands
uv run aish shell-init zsh    # output shell integration code
uv run aish start             # start the daemon
uv run aish stop              # stop the daemon
uv run aish status            # check daemon status
```

## Key Design Decisions

- **Never auto-execute** — all suggestions are shown as editable ghost text
- **Ghost text via /dev/tty** — POSTDISPLAY doesn't render ANSI escapes on zsh 5.9 macOS; $BUFFER is empty in `zle -F` callbacks. Direct `echo -n '\e[90m'... > /dev/tty` is the only working approach.
- **zsocket for IPC** — `zsh/net/socket` provides native Unix socket access without spawning subprocesses per request. The fd integrates with `zle -F` for async response handling.
- **Shell file inlining** — `shell-init` reads and prints the contents of all .zsh files rather than emitting `source` commands. Avoids path resolution issues with pipx/uv tool installs.
- **Adaptive debounce** — 200ms base, 100ms when buffer ≥8 chars. Timer via `exec {fd}< <(sleep ...)` + `zle -F`.
- **Circuit breaker** — 3 consecutive failures → 30s cooldown → probe
- **Idle timeout** — daemon auto-exits after 30 minutes of inactivity
- **Rate limiting** — 60 requests/minute to prevent burning API quota
- **Safety** — dangerous command warnings, secret sanitization before LLM calls
- **Completion spacing** — `_ensure_leading_space()` in `daemon.py` adds spaces before `-|>&;<()` tokens
- **Code fence stripping** — `_strip_code_fences()` regex removes markdown wrapping from LLM responses
- **Prompt caching** — Anthropic `cache_control: ephemeral` on system prompt + beta header
- **Temperature 0.3** — balances useful multi-token completions with determinism; 0 produces minimal completions
- **Auto-reload** — the shell checks if any `.py` source file is newer than the daemon's PID file (every 30 commands) and silently restarts the daemon when changes are detected
- **Socket liveness probe** — `shell-init` tries `zsocket` connect (not just file existence) to detect stale sockets from crashed daemons
- **recursive-edit** — NL command and history search use ZLE recursive-edit for full line editing instead of raw `read -r`
- **Ctrl+Z undo** — reverts NL-generated commands back to the original buffer
- **Model aliases over dated snapshots** — always use short model aliases (e.g. `claude-sonnet-4-5`, `claude-haiku-4-5`, `gpt-4o`) instead of dated snapshot names
