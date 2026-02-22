# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**ghst** (AI Shell) is an LLM-powered zsh plugin that provides ghost-text autocomplete, natural language command generation, error correction, and history search — all via a background Python daemon connected to ZLE (Zsh Line Editor) over a Unix domain socket.

## Architecture

### Two-process design

```
zsh (ZLE widgets)  ←──── Unix domain socket ────→  ghstd (Python async daemon)
  autocomplete.zsh                                    daemon.py (asyncio)
  nl-command.zsh                                      llm.py (httpx)
  ghst.zsh (main)                                     context.py, safety.py, config.py
```

The zsh side sends newline-delimited JSON requests; the daemon responds with completions. The socket lives at `$XDG_RUNTIME_DIR/ghst.sock` (fallback: `/tmp/ghst-$UID.sock`).

Shell files are **inlined** into the `eval "$(ghst shell-init zsh)"` output at init time — they are NOT sourced at runtime. This avoids path resolution issues with non-standard installs (pipx, uv tool, etc.).

### File layout

```
src/ghst/
  __init__.py
  __main__.py    – python -m ghst entry point
  cli.py         – CLI commands (shell-init, start, stop, status, init, model, provider, etc.)
  config.py      – ~/.config/ghst/config.toml parsing, defaults, env var override
  daemon.py      – asyncio socket server, request routing, session buffer, rate limiting, idle timeout
  llm.py         – async LLM client (OpenAI + Anthropic), circuit breaker, caching, prompt caching
  prompts.py     – system/user prompt templates for all request types
  context.py     – cwd/git/env/project-type context gathering & caching
  safety.py      – dangerous-command detection, history/output sanitization
  shell/
    ghst.zsh           – precmd/preexec hooks, history helper, auto-reload, cheat sheet
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

### Configuration (`~/.config/ghst/config.toml`)

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
uv run basedpyright src/ghst/

# CLI commands
uv run ghst shell-init zsh    # output shell integration code
uv run ghst start             # start the daemon
uv run ghst stop              # stop the daemon
uv run ghst status            # check daemon status
```

## Key Design Decisions

- **Never auto-execute** — all suggestions are shown as editable ghost text
- **Ghost text via /dev/tty** — POSTDISPLAY doesn't render ANSI escapes on zsh 5.9 macOS; $BUFFER is empty in `zle -F` callbacks. Direct `echo -n '\e[90m'... > /dev/tty` is the only working approach.
- **All colored output via /dev/tty** — POSTDISPLAY cannot render ANSI escape sequences at all on zsh 5.9 macOS. Any colored UI element (status messages, spinners, ghost text) must write directly to `/dev/tty`. POSTDISPLAY should only be used for plain uncolored text.
- **ANSI-C quoting in eval** — `$'\e[36m'` does NOT work inside `"${param:-...}"` double-quoted parameter expansion when shell code runs through `eval "$(cmd)"`. Always assign defaults separately: `typeset -g VAR=$'\e[36m'` then `[[ -n "$OVERRIDE" ]] && VAR="$OVERRIDE"`.
- **PROMPT escape wrapping** — escape sequences in zsh PROMPT must be wrapped in `%{...%}` (e.g. `%{$'\e[36m'%}text%{$'\e[0m'%}`) so ZLE calculates cursor position correctly. Without this, line editing breaks on long inputs.
- **Configurable UI colors** — all colored UI elements (ghost text, accent, success, warning, error) are configurable via `config.toml`. Colors are converted to escape sequences in `cli.py` and exported as `__GHST_*_ESC` env vars. Shell code sets ANSI defaults then overrides from env vars.
- **zsocket for IPC** — `zsh/net/socket` provides native Unix socket access without spawning subprocesses per request. The fd integrates with `zle -F` for async response handling.
- **Shell file inlining** — `shell-init` reads and prints the contents of all .zsh files rather than emitting `source` commands. Avoids path resolution issues with pipx/uv tool installs.
- **Adaptive debounce** — 200ms base, 100ms when buffer ≥8 chars. Timer via `exec {fd}< <(sleep ...)` + `zle -F`.
- **Circuit breaker** — 3 consecutive failures → 30s cooldown → probe
- **Idle timeout** — daemon auto-exits after 30 minutes of inactivity
- **Rate limiting** — 60 requests/minute to prevent burning API quota
- **Safety** — dangerous command warnings, secret sanitization before LLM calls
- **FIM-style autocomplete prompt** — system prompt tells the model to "continue the text from where it left off" (like Tab completion). This avoids spacing/restructuring issues that instruction-following prompts cause.
- **Rich autocomplete context** — every autocomplete request includes cwd, directory listing, git branch/status/branches, project type (from marker files), active virtualenv/conda, and recent history. The model sees the real environment instead of relying on post-processing hacks.
- **Completion spacing** — `_ensure_leading_space()` in `daemon.py` adds spaces before `-|>&;<()` tokens
- **Code fence stripping** — `_strip_code_fences()` regex removes markdown wrapping from LLM responses
- **Prompt caching** — Anthropic `cache_control: ephemeral` on system prompt + beta header
- **Temperature 0.3** — balances useful multi-token completions with determinism; 0 produces minimal completions
- **Auto-reload** — the shell checks if any `.py` source file is newer than the daemon's PID file (every 30 commands) and silently restarts the daemon when changes are detected
- **Socket liveness probe** — `shell-init` tries `zsocket` connect (not just file existence) to detect stale sockets from crashed daemons
- **recursive-edit** — NL command and history search use ZLE recursive-edit for full line editing instead of raw `read -r`
- **Disable autocomplete during recursive-edit** — `__ghst_self_insert` (bound to all printable chars) triggers autocomplete on every keystroke. During NL/history recursive-edit, this sends the user's English text as autocomplete requests, producing garbage responses and stale FDs that interfere after the widget returns. Use `__GHST_AUTOCOMPLETE_DISABLED` flag, set in `__ghst_enter_mode`/`__ghst_exit_mode`.
- **Clean up autocomplete FDs before and after NL/history** — stale `zle -F` response FDs from before entering NL mode can fire after the widget places its result in BUFFER. The `zle -R` in `__ghst_on_response` redraws and wipes the generated command. Cancel debounce and close response FDs at mode entry AND after the spinner/request completes.
- **Never interpolate user data into Python strings** — shell history, user input, and buffer contents must be piped through stdin to `python3` for JSON encoding. Direct interpolation into triple-quoted strings (`'''$var'''`) breaks on quotes, backslashes, and special characters, producing invalid JSON.
- **IPC timeouts** — `__ghst_request` must have a timeout (socat `-T`, python `settimeout`). Without it, socat hangs forever on stale sockets from crashed daemons, freezing the shell.
- **Ctrl+Z undo** — reverts NL-generated commands back to the original buffer
- **Model aliases over dated snapshots** — always use short model aliases (e.g. `claude-sonnet-4-5`, `claude-haiku-4-5`, `gpt-4o`) instead of dated snapshot names
