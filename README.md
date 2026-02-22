# aish — AI-powered shell plugin

LLM-powered ghost-text autocomplete, natural language commands, and semantic history search for zsh. Works with any terminal emulator that supports ANSI escapes — no terminal modifications needed.

## Features

- **Autocomplete** — Ghost text suggestions as you type, powered by an LLM with shell context. Accept with Tab/→.
- **Natural Language Commands** — Press Ctrl+G, describe what you want in English, get a shell command.
- **History Search** — Press Ctrl+R to search your shell history with natural language instead of substring matching.

## Install

```bash
uv tool install aish
```

Or install for development:

```bash
git clone https://github.com/your-org/aish.git
cd aish
uv venv && source .venv/bin/activate
uv pip install -e ".[dev]"
```

## Setup

```bash
aish init
```

This runs an interactive wizard that:
1. Detects your shell and prints the source line for your `.zshrc`
2. Prompts for your LLM provider (OpenAI or Anthropic) and API key
3. Writes `~/.config/aish/config.toml`
4. Starts the daemon and verifies the connection

Add to your `.zshrc`:

```bash
eval "$(aish shell-init zsh)"
```

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
aish> find python files modified this week
$ find . -name "*.py" -mtime -7█
```

The generated command is placed in your buffer for review — **never auto-executed**. Press **Ctrl+Z** to undo and restore your original buffer.

### History Search (Ctrl+R)

```
aish history> that docker command for postgres
  → docker exec -it postgres-dev psql -U admin -d myapp
    docker run -d --name postgres-dev -e POSTGRES_PASSWORD=secret postgres:15
```

### Cheat Sheet (Ctrl+/)

Press Ctrl+/ at any time to see a quick reference of all shortcuts.

## Configuration

Config file: `~/.config/aish/config.toml`

```toml
[provider]
name = "openai"                         # "openai" or "anthropic"
api_key = "sk-..."                      # Or set AISH_API_KEY env var
model = "gpt-4o"                        # Model for NL commands
autocomplete_model = "gpt-4o-mini"      # Fast model for autocomplete

[ui]
autocomplete_delay_ms = 200             # Debounce delay (ms)
autocomplete_min_chars = 3              # Min chars before autocomplete fires
nl_hotkey = "^G"                        # NL command hotkey
history_search_hotkey = "^R"            # History search hotkey
```

See `config/default.toml` for all available settings.

## CLI Commands

| Command | Description |
|---|---|
| `aish init` | Interactive setup wizard |
| `aish start` | Start the daemon |
| `aish stop` | Stop the daemon |
| `aish status` | Show daemon health and config |
| `aish shell-init zsh` | Output shell integration code |
| `aish help` | Show all commands and shortcuts |

## Architecture

```
zsh (ZLE widgets)  ←── Unix domain socket ──→  aishd (Python daemon)
  autocomplete.zsh                               daemon.py (asyncio)
  nl-command.zsh                                 llm.py (httpx)
  history-search.zsh                             safety.py, config.py
```

The shell side sends JSON requests over a Unix socket; the daemon routes them to the LLM and returns suggestions. The daemon runs in the background, auto-starts on first use, and auto-restarts when Python source files change (for seamless development).

## Privacy

aish sends the following data to your configured LLM provider:

- **Current buffer** (what you've typed so far)
- **Current working directory**
- **Recent shell history** (last 5-10 commands)

aish does **NOT** send:

- File contents (unless they appear in terminal output)
- Environment variables or full PATH
- SSH keys, passwords, or other credentials

All sensitive data (API keys, passwords, tokens) is automatically stripped from history and terminal output before sending to the LLM.

## Roadmap

Planned features for future releases:

- **Error Correction** — Auto-suggest fixes as ghost text when a command fails
- **Proactive Suggestions** — Read the last command's output and suggest the next command on an empty prompt
- **Bash & Fish Support** — Extend autocomplete and NL commands beyond zsh
- **Local Model Support** — Optimized flows for Ollama, LM Studio, and other local inference servers
- **Homebrew Installation** — `brew install aish` via a Homebrew tap

## Development

```bash
uv venv && source .venv/bin/activate
uv pip install -e ".[dev]"
uv run pytest              # Run tests
uv run pytest -v           # Verbose
uv run ruff check src/     # Lint
uv run basedpyright src/aish/  # Type check
```

The daemon auto-reloads during development: every 30 commands, the shell checks if any `.py` source file is newer than the running daemon and restarts it if so. No manual `aish stop && aish start` needed after editing Python code.

## License

MIT
