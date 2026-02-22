# ghst — AI-powered shell plugin

LLM-powered ghost-text autocomplete, natural language commands, and semantic history search for zsh. Works with any terminal emulator that supports ANSI escapes — no terminal modifications needed.

## Features

- **Autocomplete** — Ghost text suggestions as you type, powered by an LLM with shell context. Accept with Tab/→.
- **Natural Language Commands** — Press Ctrl+G, describe what you want in English, get a shell command.
- **History Search** — Press Ctrl+R to search your shell history with natural language instead of substring matching.

## Install

### uv (recommended)

```bash
uv tool install ghst
```

### pipx

```bash
pipx install ghst
```

### pip

```bash
pip install ghst
```

Then run the setup wizard:

```bash
ghst init
exec zsh
```

The `init` wizard configures your LLM provider, adds shell integration to `.zshrc`, starts the daemon, and verifies the connection. `exec zsh` reloads your shell to activate it.

## Development Setup

```bash
git clone https://github.com/insprd/ghst.git
cd ghst
uv venv && source .venv/bin/activate
uv pip install -e ".[dev]"
ghst init        # configure provider + inject zshrc
exec zsh         # reload shell to activate
```

> **Note:** In dev mode, you must activate the venv (`source .venv/bin/activate`) in each new shell for `ghst` to resolve to your local checkout. Alternatively, use `uv run ghst` without activating. The `eval "$(ghst shell-init zsh)"` line in your `.zshrc` handles this automatically once the venv is active.

## Usage

### Autocomplete

Just start typing. After a brief pause, ghost text appears with a suggestion:

```
$ git sta‹tus --short›
```

- **Tab** or **→** — Accept the full suggestion
- **Shift+→** — Accept one word at a time
- **Esc** — Dismiss

### Natural Language Commands (Ctrl+G)

```
$ █                          # Press Ctrl+G
ghst> find python files modified this week
$ find . -name "*.py" -mtime -7█
```

The generated command is placed in your buffer for review — **never auto-executed**. Press **Ctrl+Z** to undo and restore your original buffer.

### History Search (Ctrl+R)

```
ghst history> that docker command for postgres
  → docker exec -it postgres-dev psql -U admin -d myapp
    docker run -d --name postgres-dev -e POSTGRES_PASSWORD=secret postgres:15
```

### Cheat Sheet (Ctrl+/)

Press Ctrl+/ at any time to see a quick reference of all shortcuts.

## Configuration

Config file: `~/.config/ghst/config.toml`

```toml
[provider]
name = "openai"                         # "openai" or "anthropic"
api_key = "sk-..."                      # Or set GHST_API_KEY env var
model = "gpt-4o"                        # Model for NL commands
autocomplete_model = "gpt-4o-mini"      # Fast model for autocomplete

[ui]
autocomplete_delay_ms = 200             # Debounce delay (ms)
autocomplete_min_chars = 3              # Min chars before autocomplete fires
nl_hotkey = "^G"                        # NL command hotkey
history_search_hotkey = "^R"            # History search hotkey
ghost_color = "#6e7681"                 # Ghost text color (hex or 256-color index)
accent_color = "#79c0ff"                # Prompt accent color (ghst>, spinner)
success_color = "#56d364"               # Success indicator (✓)
warning_color = "#e3b341"               # Warning indicator (⚠)
error_color = "#f85149"                 # Error indicator (✗)
```

See `config/default.toml` for all available settings.

## CLI Commands

| Command | Description |
|---|---|
| `ghst init` | Interactive setup wizard |
| `ghst start` | Start the daemon |
| `ghst stop` | Stop the daemon |
| `ghst status` | Show daemon health and config |
| `ghst shell-init zsh` | Output shell integration code |
| `ghst help` | Show all commands and shortcuts |

## Architecture

```
zsh (ZLE widgets)  ←── Unix domain socket ──→  ghstd (Python daemon)
  autocomplete.zsh                               daemon.py (asyncio)
  nl-command.zsh                                 llm.py (httpx)
  history-search.zsh                             safety.py, config.py
```

The shell side sends JSON requests over a Unix socket; the daemon routes them to the LLM and returns suggestions. The daemon runs in the background, auto-starts on first use, and auto-restarts when Python source files change (for seamless development).

## Context Awareness

Autocomplete suggestions are informed by your full working environment — not just what you've typed. Every request includes:

| Context | Example | What it helps with |
|---|---|---|
| **Directory listing** | `src/  tests/  README.md` | `cd`, `cat`, `vim` suggest real file/folder names |
| **Git branch & status** | `on main (dirty)` | `git commit`, `git push`, `git stash` awareness |
| **Git branches** | `feature/auth, develop, next` | `git checkout`, `git merge` suggest real branch names |
| **Project type** | `python, docker` | Suggests `uv run pytest` instead of `npm test` |
| **Active environment** | `venv:.venv` | Knows `python` resolves to the venv, not system |
| **Recent commands** | last 5 from history | Learns your patterns within the session |
| **Exit status** | `0` or `1` | Knows if the last command failed |

All context is gathered locally and cached (5s TTL) to avoid redundant work during rapid typing. Project type is detected from marker files in the current directory:

`package.json` · `pyproject.toml` · `Cargo.toml` · `go.mod` · `Gemfile` · `Makefile` · `Dockerfile` · `docker-compose.yml` · `CMakeLists.txt` · `pom.xml` · `build.gradle` · `justfile` · `Taskfile.yml`

## Privacy

ghst sends the following data to your configured LLM provider:

- **Current buffer** (what you've typed so far)
- **Current working directory** and **directory listing** (non-hidden files/folders)
- **Recent shell history** (last 5-10 commands)
- **Git context** — current branch, dirty status, local branch names
- **Project type** — detected from marker files (e.g. `package.json`, `pyproject.toml`, `Cargo.toml`)
- **Active environment** — virtualenv name, conda env, `NODE_ENV`

ghst does **NOT** send:

- File contents (unless they appear in terminal output)
- Hidden/dotfiles or environment variables
- SSH keys, passwords, or other credentials

All sensitive data (API keys, passwords, tokens) is automatically stripped from history and terminal output before sending to the LLM.

## Roadmap

Planned features for future releases:

- **Error Correction** — Auto-suggest fixes as ghost text when a command fails
- **Proactive Suggestions** — Read the last command's output and suggest the next command on an empty prompt
- **Bash & Fish Support** — Extend autocomplete and NL commands beyond zsh
- **Local Model Support** — Optimized flows for Ollama, LM Studio, and other local inference servers
- **Homebrew Installation** — `brew install ghst` via a Homebrew tap

## Development

```bash
uv run pytest              # Run tests
uv run pytest -v           # Verbose
uv run ruff check src/     # Lint
uv run basedpyright src/ghst/  # Type check
```

The daemon auto-reloads during development: every 30 commands, the shell checks if any `.py` source file is newer than the running daemon and restarts it if so. No manual `ghst stop && ghst start` needed after editing Python code.

## License

MIT
