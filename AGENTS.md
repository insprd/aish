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

### File layout

```
src/aish/
  __init__.py
  __main__.py    – python -m aish entry point
  cli.py         – CLI commands (shell-init, start, stop, status)
  config.py      – ~/.config/aish/config.toml parsing, defaults, env var override
  daemon.py      – asyncio socket server, request routing, session buffer
  llm.py         – async LLM client (OpenAI + Anthropic), circuit breaker, caching
  prompts.py     – system/user prompt templates for all request types
  context.py     – cwd/git/env context gathering & caching
  safety.py      – dangerous-command detection, history/output sanitization
shell/
  zsh/aish.zsh           – precmd/preexec hooks, output capture, proactive suggestions
  zsh/autocomplete.zsh   – ghost text via terminal escape codes, adaptive debounce
  zsh/nl-command.zsh     – Ctrl+G natural-language widget
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
- **Proactive suggestions** — suggests commands on empty buffer from terminal output
- **Adaptive debounce** — 200ms base, 100ms when buffer ≥8 chars
- **Circuit breaker** — 3 consecutive failures → 30s cooldown → probe
- **Safety** — dangerous command warnings, secret sanitization before LLM calls
- **Zero terminal modifications** — works with any terminal via standard ZLE
- **Completion spacing** — `_ensure_leading_space()` in `daemon.py` prevents LLM completions from merging into the buffer (e.g. `ffmpeg` + `-i` → `ffmpeg -i`). LLM responses use `.rstrip()` instead of `.strip()` to preserve leading whitespace.
- **Auto-reload** — the shell checks if any `.py` source file is newer than the daemon's PID file (every 30 commands) and silently restarts the daemon when changes are detected. `shell-init` exports `__AISH_SRC_DIR` for this check.
- **Model aliases over dated snapshots** — always use short model aliases (e.g. `claude-sonnet-4-5`, `claude-haiku-4-5`, `gpt-4o`) instead of dated snapshot names (e.g. `claude-haiku-4-5-20251001`). Aliases auto-resolve to the latest version, avoiding stale pinned models.
