# aish: LLM-Powered Shell Plugin

## Overview

**aish** (AI Shell) is an open source shell plugin (zsh first, then bash/fish) that adds two LLM-powered features to any modern terminal emulator (Ghostty, iTerm2, Kitty, Alacritty, WezTerm, etc.). It runs as shell scripts + a lightweight background daemon, requiring zero modifications to the terminal.

### Features

1. **Autocomplete** — As you type, the plugin suggests command completions inline (ghost text), powered by an LLM with shell context. Accept with Tab/→.
2. **Natural Language Command Construction** — Press a hotkey to open a prompt where you describe what you want in plain English. The LLM generates the shell command and places it on your command line for review before execution.
3. **Error Correction** — When a command fails, aish reads the error output and suggests a corrected command as ghost text on the next prompt. Accept with Tab/→ like autocomplete.
4. **Natural Language History Search** — Semantic search over shell history using plain English. Press Ctrl+R to describe what you're looking for instead of exact substring matching.

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Shell (zsh)                                    │
│  ┌────────────────────┐  ┌────────────────────┐ │
│  │ ZLE widget:        │  │ ZLE widget:        │ │
│  │ autocomplete hook  │  │ NL prompt (hotkey) │ │
│  └────────┬───────────┘  └────────┬───────────┘ │
│           │                       │              │
│           ▼                       ▼              │
│  ┌─────────────────────────────────────────────┐ │
│  │  aishd (background daemon)                  │ │
│  │  - Receives requests over Unix domain socket│ │
│  │  - Manages LLM API calls (async, streaming) │ │
│  │  - Caches context, handles rate limiting     │ │
│  │  - Written in Python (simple, portable)      │ │
│  └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

### Why a daemon?

- Shell script alone can't do async HTTP without blocking the prompt
- A persistent process can maintain context, cache results, and stream responses
- Unix socket IPC is near-instant and avoids port conflicts
- The daemon starts lazily on first use and auto-exits after idle timeout

---

## Implementation Plan

### Phase 1: Project Scaffolding

- Initialize the repo with a clear directory structure:
  - `bin/` — daemon entry point
  - `shell/` — shell integration scripts (zsh/, bash/, fish/)  
  - `src/` — Python daemon source
  - `config/` — default configuration
- Create a `setup.sh` installer script that:
  - Checks for Python 3.8+
  - Creates a virtualenv or uses pipx
  - Installs Python dependencies
  - Prints the shell source line to add to `.zshrc`
- Implement `aish shell-init zsh` — a CLI subcommand that outputs the sourceable shell integration code. Users add `eval "$(aish shell-init zsh)"` to `.zshrc`. This is the single entry point that loads all ZLE widgets, hooks, and daemon auto-start logic.
- API key loading with priority order:
  1. Environment variable (`AISH_API_KEY`)
  2. Config file (`~/.config/aish/config.toml`)
  3. System keychain (stretch goal)
- Create a configuration file format (`~/.config/aish/config.toml`) for:
  - `provider` — "openai" or "anthropic"
  - `api_key` — LLM provider API key (or env var `AISH_API_KEY`)
  - `api_base_url` — API endpoint; defaults per provider, user-configurable for any OpenAI-compatible server
  - `model` — model for NL command construction (e.g. "gpt-4o", "claude-sonnet-4-5")
  - `autocomplete_model` — separate fast model for autocomplete (e.g. "gpt-4o-mini", "claude-haiku-4-5"); defaults to `model` if not set
  - `autocomplete_delay_ms` — base debounce delay before triggering autocomplete (default: 200)
  - `autocomplete_delay_short_ms` — reduced debounce delay used when buffer length ≥ `autocomplete_delay_threshold` (default: 100); longer buffers give the LLM more signal, so less wait is needed
  - `autocomplete_delay_threshold` — character count at which debounce switches from `autocomplete_delay_ms` to `autocomplete_delay_short_ms` (default: 8)
  - `autocomplete_min_chars` — minimum chars typed before autocomplete fires (default: 3)
  - `autocomplete_hotkey` — key to accept suggestion (default: right-arrow or Tab)
  - `nl_hotkey` — hotkey to open NL prompt (default: Ctrl+G)
  - `history_search_hotkey` — hotkey to open NL history search (default: Ctrl+R; replaces zsh's built-in reverse search with a semantic upgrade)
  - `history_search_limit` — max history entries to send to LLM (default: 500)
  - `error_correction` — enable/disable error correction (default: true)
  - `proactive_suggestions` — enable/disable proactive command suggestions from terminal output (default: true)
  - `proactive_output_lines` — max lines of terminal output to capture and send to LLM (default: 50)
  - `proactive_capture_blocklist` — list of commands to skip output capture for, e.g. interactive programs (default: vim, nvim, less, top, htop, ssh, tmux, screen, man, watch, fzf, python, node, irb)
  - `cheat_sheet_hotkey` — hotkey to show in-shell shortcut reference (default: Ctrl+/)

### Phase 2: Daemon Core

- Build a Python daemon (`aishd`) that:
  - Listens on a Unix domain socket at `$XDG_RUNTIME_DIR/aish.sock` (or `/tmp/aish-$UID.sock`)
  - Accepts newline-delimited JSON messages from the shell
  - Routes requests to the appropriate handler (autocomplete vs. NL command)
  - Calls the LLM API asynchronously using `asyncio` + `httpx`
  - Returns responses as newline-delimited JSON
  - Implements graceful shutdown, PID file, and idle auto-exit (e.g. 30 min)
- LLM client (`llm.py`):
  - `OpenAIClient` for OpenAI and any OpenAI-compatible API
  - `AnthropicClient` adapter for Anthropic's API format
  - Both implement `async complete(messages) -> str` with streaming support
  - Connection pooling via persistent `httpx.AsyncClient` with keep-alive and HTTP/2
  - **Per-request-type timeouts**: 1s connect + 3s read for autocomplete/proactive/error-correction; 2s connect + 12s read for NL commands/history search (see Network Resilience Strategy)
  - **Retry policy**: No retries for autocomplete/proactive/error-correction (speed over persistence). 1 retry with 500ms delay for NL commands/history search (user is waiting explicitly).
  - **Response caching**: In-memory dict keyed by `(buffer_prefix, cwd)` for autocomplete and `(last_command, cwd, output_hash)` for proactive suggestions. ~60s TTL. Cache is checked before making any LLM call.
- Request/response protocol (simple, over Unix socket):
  - **Autocomplete request**: `{"type": "complete", "buffer": "git sta", "cwd": "/path", "shell": "zsh", "history": ["last 5 cmds"]}`
  - **Proactive autocomplete request** (empty buffer + terminal output): `{"type": "complete", "buffer": "", "cwd": "/path", "shell": "zsh", "history": ["last 5 cmds"], "last_command": "copilot", "last_output": "...\nResume this session with copilot --resume=64a1..."}`
  - **Autocomplete response**: `{"type": "complete", "suggestion": "tus --short"}`
  - **NL request**: `{"type": "nl", "prompt": "find all python files modified today", "cwd": "/path", "shell": "zsh"}`
  - **NL response**: `{"type": "nl", "command": "find . -name '*.py' -mtime 0"}`
  - **Config reload**: `{"type": "reload_config"}` → `{"type": "reload_config", "ok": true}` — daemon hot-reloads config without restart
  - **Error correction request**: `{"type": "error_correct", "failed_command": "git pussh origin main", "exit_status": 1, "stderr": "git: 'pussh' is not a git command.", "cwd": "/path", "shell": "zsh"}`
  - **Error correction response**: `{"type": "error_correct", "suggestion": "git push origin main"}`
  - **History search request**: `{"type": "history_search", "query": "that docker command for the postgres container", "history": ["last 500 cmds"], "shell": "zsh"}`
  - **History search response**: `{"type": "history_search", "results": [{"command": "docker exec -it postgres-dev psql -U admin -d myapp", "score": 0.95}, ...]}`
- LLM prompt engineering (`prompts.py`):
  - System prompt establishes the LLM as a shell expert for the detected OS/shell
  - Autocomplete prompt: given current buffer + cwd + recent history, return ONLY the completion suffix (no explanation)
  - Proactive autocomplete prompt: given the last command's terminal output + session buffer + cwd + history, return ONLY the most likely next command the user would run (no explanation). Handles both explicit commands in output (e.g. "Resume with copilot --resume=...") and general predictions (e.g. suggesting `git mergetool` after merge conflict output). Prompt is structured with stable prefix (system + session buffer) for cache hit optimization.
  - NL prompt: given natural language description + cwd + shell, return ONLY the command (no explanation)
  - Error correction prompt: given failed command + stderr + exit status, return ONLY the corrected command (no explanation)
  - History search prompt: given natural language query + full history, return matching commands ranked by relevance
  - All prompts instruct the LLM to return empty string if unsure (never hallucinate dangerous commands)

### Phase 3: Autocomplete (ZLE Integration)

- Create a zsh ZLE widget that:
  - On each keystroke (via `zle-line-pre-redraw` or a custom `self-insert` wrapper), sends the current `$BUFFER` to the daemon
  - Implements debouncing: only sends after `autocomplete_delay_ms` of no typing (use `zle -F` with a file descriptor timer or `sched`)
  - Receives the suggestion and displays it as dimmed/grey ghost text after the cursor using ANSI escape sequences (similar to how `zsh-autosuggestions` works — by appending to `$POSTDISPLAY`)
  - On Tab or →, accepts the suggestion by appending it to `$BUFFER`
  - On any other key, clears the ghost text
  - Cancels in-flight requests when the user keeps typing (the daemon handles this via request IDs)
- **Proactive suggestions** — suggest commands on an empty buffer based on terminal output:
  - **Output capture** (`preexec`/`precmd` hooks):
    - In `preexec`: create temp file, save original fds via `exec {fd}>&1`, tee stdout+stderr to temp file via `exec > >(tee ...)  2> >(tee ... >&2)`
    - In `precmd`: restore original fds, read last `proactive_output_lines` (default 50) lines from temp file, strip ANSI escape codes, delete temp file
    - **Interactive command blocklist**: check first word of command against `proactive_capture_blocklist` config (default: vim, nvim, less, top, htop, ssh, tmux, screen, man, watch, fzf, python, node, irb). Skip capture entirely for matching commands to avoid breaking raw terminal mode.
    - Clean up orphaned temp files on shell startup (glob `/tmp/aish-out-*.XXXXXX`)
  - **Heuristic pre-filter** (shell-side, no daemon call):
    - Regex scan of captured output for actionable patterns: phrases like "run", "try", "use", "resume with"; backtick-quoted commands; lines starting with `$` or `>`; known tool patterns (`--set-upstream`, `audit fix`, `--resume=`); action words ("fix", "resolve", "install", "update", "upgrade")
    - Non-zero exit status always qualifies
    - No match → skip, no API call, no ghost text
  - **Background prefetch**: send the proactive `complete` request to the daemon during `precmd`, *before* the prompt draws. The daemon starts LLM inference while zsh renders the prompt. On fast connections with prompt caching, the response can arrive before the user sees the prompt (zero perceived latency).
  - **Two-tier context**:
    - **Tier 1 — Per-command output** (shell-side): The last 50 lines of the most recent command's stdout+stderr. This is the primary signal — covers explicit "try this" messages, error output, and tool suggestions. Sent via `last_output` in the request.
    - **Tier 2 — Rolling session buffer** (daemon-side): The daemon maintains a circular buffer of the last 20 commands and their truncated outputs (last 20 lines each). This gives the LLM session-level awareness — e.g., if the user ran `git status` → `cat file.py` → empty prompt, the daemon knows about the merge conflicts from `git status` even though the last command was `cat`. The buffer is stored in daemon memory (lost on restart, which is fine — session context is ephemeral). No RAG or embedding needed: modern LLM context windows (128k+) easily fit 20 commands × 20 lines of output, so the full session buffer is included directly in the prompt.
  - **Same UX as autocomplete**: The suggestion appears as ghost text on the fresh prompt. Tab/→ to accept, any other key to dismiss. No new keybindings or modes to learn.
  - **Priority**: If both proactive suggestions and error correction fire (non-zero exit with actionable output), error correction takes priority since it's a direct fix for the failed command.
  - **No debounce**: Proactive requests fire once in `precmd`, not on a timer.
  - On by default; disable with `proactive_suggestions = false` in config
- **Cheat sheet widget** (Ctrl+/):
  - ZLE widget bound to `cheat_sheet_hotkey` (default: `Ctrl+/`)
  - Sets `$POSTDISPLAY` to a formatted shortcut reference (Tab/→, Esc, Ctrl+G, Ctrl+R, Ctrl+/)
  - Next keystroke clears `$POSTDISPLAY` and falls through to normal input
  - Purely shell-side — no daemon communication
- **First-use hint**:
  - On the first autocomplete suggestion after onboarding, show a one-time hint in `$POSTDISPLAY`: `"aish: ghost text suggestion (Tab to accept, → to accept word, Esc to dismiss)"`
  - Suppressed after first display by writing a `~/.config/aish/.onboarded` marker file
- Performance considerations:
  - The adaptive debounce prevents flooding the LLM API
  - `$POSTDISPLAY` is the correct zsh mechanism for ghost text (no terminal hacks needed)
  - Communication with daemon is async via `zle -F` (fd-based event handling) so the prompt never blocks
  - If the daemon is unreachable or slow, the shell degrades gracefully (no ghost text, no errors)
  - Proactive suggestions use the heuristic pre-filter to avoid LLM calls on routine output

### Phase 4: Natural Language Command Construction

- Create a zsh ZLE widget bound to a configurable hotkey (default `Ctrl+G`) that:
  - Saves the current `$BUFFER`
  - Prompts the user inline for a natural language description (using `zle recursive-edit` or a simple read into a prompt region)
  - Sends the description to the daemon as an NL request
  - Shows a brief "thinking..." indicator (e.g. a spinner in `$POSTDISPLAY`)
  - On response, places the generated command into `$BUFFER` (replacing or appending)
  - The user can then review, edit, and press Enter to execute — or Ctrl+C to cancel
  - The command is NEVER auto-executed; always requires explicit Enter
- UX details:
  - If the user had partial text in `$BUFFER`, include it as additional context
  - Show the generated command with a brief visual indicator (e.g. different color for 1 second) so it's obvious it was AI-generated
  - Support Ctrl+Z or Escape to undo/cancel and restore the original buffer

### Phase 4b: Error Correction

- Hook into the `precmd` zsh function (runs before each prompt is drawn):
  - Capture the previous command's exit status (`$?`) and the last line(s) of stderr
  - If exit status is non-zero and stderr is non-empty, send an error correction request to the daemon
  - Display the corrected command as ghost text on the fresh prompt, identical to autocomplete UX (`$POSTDISPLAY`, Tab/→ to accept)
  - If the user starts typing something else, the correction is dismissed (same as autocomplete)
- Stderr capture strategy:
  - Use `exec 2> >(tee ...)` or a zsh `preexec`/`precmd` hook pair to capture stderr to a temp buffer
  - Only capture the last N lines (e.g. 20) to avoid sending huge outputs to the LLM
  - Strip ANSI escape codes before sending
- Types of errors handled:
  - Typos: `git pussh` → `git push`
  - Missing arguments: `grep -r` → `grep -r "pattern" .`
  - Wrong flags: `tar -xzf file.tar.bz2` → `tar -xjf file.tar.bz2`
  - Package not found: `pip install reqeusts` → `pip install requests`
  - Permission errors: `cat /etc/shadow` → `sudo cat /etc/shadow`
  - File not found: `cd /usr/locla/bin` → `cd /usr/local/bin`
- Performance:
  - Uses the autocomplete model (fast/small) since corrections are simple
  - 5s timeout, same as autocomplete
  - No debounce needed — fires once per failed command

### Phase 4c: Natural Language History Search

- Create a zsh ZLE widget bound to a configurable hotkey (default `Ctrl+R`) that:
  - Opens an inline search prompt: `aish history> █`
  - User types a natural language description of what they're looking for
  - On Enter, sends the query + full shell history to the daemon
  - Daemon uses the LLM to rank history entries by semantic relevance
  - Results displayed as a selectable list (similar to fzf):
    ```
    aish history> docker command for postgres
      → docker exec -it postgres-dev psql -U admin -d myapp
        docker run -d --name postgres-dev -e POSTGRES_PASSWORD=secret postgres:15
        docker logs postgres-dev --tail 50
    
    ↑↓ navigate, Enter to select, Esc to cancel
    ```
  - On Enter, selected command is placed into `$BUFFER` for review/execution
  - On Esc, cancel and restore original buffer
- History handling:
  - Read history via `fc -l 1` (all history) or `$HISTFILE` for full history access
  - Send up to last 500 commands (configurable via `history_search_limit`)
  - Sanitize history before sending (strip secrets/tokens, same as Phase 7 safety)
  - History is sent with the request, not stored by the daemon (privacy principle)
- Performance:
  - Uses the NL command model (smarter model, since semantic ranking is harder)
  - 10s timeout — searching large history takes longer
  - Results are returned as a ranked list, displayed incrementally if streamed
- Advantage over native Ctrl+R:
  - Native Ctrl+R is substring search: "postgres" finds it, but "that database command" doesn't
  - aish replaces the binding with a semantic upgrade — same key, much smarter search

### Phase 5: Context & History Enrichment

- Feed the LLM richer context to improve suggestion quality:
  - Last N commands from shell history (`fc -l` in zsh)
  - Current working directory and its contents (ls summary, git status if in a repo)
  - Environment hints: OS, shell version, common tools available (detected once at daemon startup)
  - For autocomplete: the previous command's exit status
  - **Rolling session buffer** for proactive suggestions: the daemon accumulates a circular buffer of the last 20 commands and their truncated outputs (last 20 lines each, ANSI-stripped). This gives session-level awareness without RAG — the entire buffer fits easily in a modern LLM's context window (128k+ tokens). The buffer is:
    - Stored in daemon memory (ephemeral — cleared on daemon restart)
    - Appended to on each proactive `complete` request that includes `last_output`
    - Included in the proactive suggestion prompt so the LLM can see "what the user has been doing"
    - Example: `git status` (conflicts) → `cat src/main.py` (file contents) → empty prompt. The daemon has both outputs in the buffer, so it can suggest `git mergetool` even though the last output was just file contents.
    - Not sent with regular autocomplete requests (buffer is non-empty, user is typing — command history alone is sufficient context)
- **Prompt caching** implementation:
  - Structure all prompts with a stable prefix (system prompt → session buffer → history) and variable suffix (current buffer / last_output) to maximize cache hit rates
  - **OpenAI**: Automatic prefix caching — no code changes needed, just consistent prompt structure
  - **Anthropic**: Explicit `cache_control` markers on the system prompt and session buffer message blocks. The `AnthropicClient` adds these markers when building the request.
  - Cache hit yields ~50% reduction in time-to-first-token on repeated requests
- Context is gathered shell-side and sent with each request; the daemon does NOT read the filesystem directly (security principle)
- Implement a context cache in the daemon so repeated cwd info isn't re-processed

### Phase 6: Local Model Support (deferred)

> Deferred to a future phase. The OpenAI-compatible code path in `llm.py` already supports local servers (Ollama, LM Studio, llama.cpp, vLLM); the main work is optimizing prompt sizes for local model throughput, handling the no-API-key flow, and tuning debounce/context settings for slower inference.

### Phase 6b: Bash & Fish Support

- Port the zsh integration to bash:
  - Use `bind -x` for keystroke hooks and `READLINE_LINE`/`READLINE_POINT` for buffer manipulation
  - Bash lacks `$POSTDISPLAY`, so ghost text uses cursor-save/restore + dim ANSI output after the cursor, then erase on next key
  - NL widget uses `bind -x` with a custom keyseq
- Port to fish:
  - Use `commandline` builtin for buffer access
  - Use `bind` for hotkeys
  - Fish's event system for async fd handling

### Phase 7: Polish & Safety

- Safety guardrails:
  - Never auto-execute generated commands
  - Warn on obviously dangerous patterns (`rm -rf /`, `:(){ :|:& };:`, `dd if=`, `mkfs`, etc.) with a visual ⚠️ indicator
  - Sanitize history and terminal output before sending to LLM (strip lines matching password/token/secret patterns)
  - API key is never logged or exposed in shell variables (read from config file or env var)
- **Network resilience** (see Network Resilience Strategy section for full design):
  - **Circuit breaker**: implement CLOSED → OPEN (30s) → HALF-OPEN → CLOSED state machine in the LLM client. 3 consecutive failures trips the breaker. Separate breaker per provider.
  - **Connection health tracking**: `ConnectionHealth` class tracking `last_success_time`, `consecutive_failures`, `avg_latency_ms`, `circuit_state`. When `avg_latency > 2s`, skip proactive suggestions (too slow to be useful).
  - **`aish status` health display**: show connection state (healthy/degraded/offline), circuit breaker state, last success time, probe countdown when OPEN
  - Daemon auto-restarts on crash (shell wrapper checks socket liveness)
  - Rate limiting to avoid burning API credits (configurable max requests/min)
- **`aish init`** — interactive setup wizard:
  - Detect shell, print `eval "$(aish shell-init zsh)"` source line
  - Prompt for provider (OpenAI / Anthropic), API key, model choices
  - **Hotkey conflict detection**: run `bindkey "^G"` to check existing bindings. If conflict found, explain existing binding, offer alternatives (`Ctrl+]`, `Ctrl+\`, `Ctrl+X Ctrl+G`). Ctrl+R override is intentional (semantic upgrade of native reverse search) and does not trigger a conflict warning.
  - Verify connection (start daemon, test completion)
  - Write `~/.config/aish/config.toml`
- **Config hot-reload**: implement the `reload_config` message handler in the daemon. When the CLI updates config via `aish set`/`aish model set`/`aish provider set`, it sends `{"type": "reload_config"}` over the socket. The daemon re-reads `config.toml` and updates model, provider, and all settings without restart.
- **Full CLI command set**:
  - `aish start` / `stop` / `status` — manage daemon
  - `aish init` — setup wizard (re-runnable)
  - `aish config` — open config file in `$EDITOR`
  - `aish model` / `aish model list` / `aish model set` — view and change models
  - `aish provider` / `aish provider set` — view and change provider
  - `aish set <key> <value>` / `aish get <key>` / `aish reset <key>` / `aish defaults` — config management
  - `aish history` — show recent AI interactions
  - `aish help` / `aish help <command>` — help screens
- **README.md**: project description, install instructions (pip/pipx/brew), usage guide, config reference, supported terminals list, privacy section documenting what data is sent to the LLM, GIF/screenshot demo
- **CONTRIBUTING.md**: dev setup, code style, PR process, issue guidelines

### Phase 8: Homebrew Distribution

- Create a Homebrew tap repository (`homebrew-aish`) containing the formula
- Formula responsibilities:
  - Declare dependency on Python 3.8+
  - Install the Python package into a Homebrew-managed virtualenv (using `virtualenv_install_with_resources`)
  - Symlink the `aish` CLI entry point to Homebrew's bin
  - Install shell completion files to the appropriate Homebrew paths
- Tap structure:
  ```
  homebrew-aish/
  └── Formula/
      └── aish.rb      # Homebrew formula
  ```
- Formula auto-update:
  - GitHub Actions workflow in the main repo: on PyPI release, open a PR against the tap repo updating the version and SHA256
  - Or use `brew bump-formula-pr` in CI
- Post-install caveats:
  - Formula prints the `eval "$(aish shell-init zsh)"` line and `aish init` instructions via Homebrew's `caveats` block
  - Users see this on `brew install` and `brew info aish`
- **GitHub Actions CI** (set up before first public release):
  - `ci.yml`: on push/PR — lint (`ruff check`), type check (`mypy`), tests (`pytest`)
  - `release.yml`: on version tag — build, publish to PyPI, update Homebrew tap formula

---

## Autocomplete Performance Strategy

The autocomplete feature must feel instant despite relying on LLM API calls. These strategies work together to minimize perceived latency:

### Avoiding unnecessary requests
- **Adaptive debouncing** — Base delay of `autocomplete_delay_ms` (default 200ms). Automatically reduced to `autocomplete_delay_short_ms` (default 100ms) when the buffer has ≥ `autocomplete_delay_threshold` (default 8) characters — longer buffers give the LLM more signal, so waiting is less necessary and the user is more likely to be mid-thought wanting a completion. All three values are user-configurable.
- **Minimum buffer threshold** — Don't fire until `autocomplete_min_chars` (default 3) characters are typed
- **Request cancellation** — When the user types another character, cancel the in-flight LLM request immediately via `request_id` tracking in the daemon; abort before consuming tokens
- **Skip when native completion is better** — Don't compete with filesystem path completion or other native shell completions mid-argument

### Reusing previous work
- **Prefix reuse** — If the daemon returned `"tus --short"` for `"git sta"` and the user types `"git stat"`, the existing suggestion still applies (`"us --short"`). Trim client-side, no new API call
- **Response caching** — Cache recent completions in a dict keyed by `(buffer_prefix, cwd)` with ~60s TTL. Common patterns like `git st`, `docker run` hit the same completions repeatedly

### Faster LLM responses
- **Small/fast model for autocomplete** — Default to the fastest cloud model available (e.g. `gpt-4o-mini`, `claude-haiku`). Separately configurable from the NL command model via `autocomplete_model` config key
- **Prompt caching** — Both OpenAI and Anthropic support prompt prefix caching. The system prompt + session buffer is mostly static between requests and is structured as a cacheable prefix. On cache hit, only the new buffer/output tokens need processing — cuts time-to-first-token by 50%+ on repeated requests. The daemon sets appropriate cache headers/parameters per provider.
- **Prompt token budget** — Keep autocomplete prompts minimal: 5 history commands max, short cwd, no verbose context. Fewer input tokens = faster time-to-first-token
- **Streaming first token** — Use streaming and show the suggestion as soon as the first meaningful chunk arrives, then append as more tokens arrive
- **Connection pooling** — Reuse `httpx.AsyncClient` with keep-alive connections to the LLM API. Eliminates TLS handshake on repeated requests (~100-200ms savings)

### Background prefetch for proactive suggestions
- **Start inference during `precmd`, before prompt draws** — The proactive LLM call is fired in `precmd` as soon as the heuristic passes, while zsh is still rendering the prompt. On fast connections, the response can arrive before the user even sees the prompt, making ghost text appear simultaneously with the prompt (zero perceived latency).
- **Overlap with prompt rendering** — zsh's `precmd` runs before the prompt is drawn. The daemon request is sent asynchronously via the socket, and `zle -F` picks up the response after the prompt appears. The prompt is never blocked — if inference takes longer, the ghost text fades in after the prompt.

### Non-blocking shell integration
- **Async IPC via `zle -F`** — fd-based event handling so the prompt never blocks waiting for a response
- **Graceful degradation** — If the daemon is unreachable, slow, or errors, the shell behaves normally (no ghost text, no error messages)
- **5s hard timeout** — Autocomplete requests that take longer than 5s are dropped silently

---

## Network Resilience Strategy

The daemon must handle spotty internet gracefully — airplane wifi, tethering, flaky connections. The core principle: **never let network issues degrade the shell experience**. No hangs, no error spam, no battery drain from retry loops.

### Timeouts (aggressive, per request type)

| Request type | Connect timeout | Read timeout | Total timeout | Why |
|---|---|---|---|---|
| Autocomplete | 1s | 3s | 5s | Speed matters most — stale suggestions are useless |
| Proactive | 1s | 3s | 5s | Same as autocomplete — if it's slow, user has moved on |
| Error correction | 1s | 3s | 5s | Same UX as autocomplete |
| NL command | 2s | 12s | 15s | User is waiting explicitly — more tolerance |
| History search | 2s | 8s | 10s | User is waiting explicitly |

Connect timeout is intentionally tight (1-2s). On a working connection, TCP+TLS completes in <200ms. A 1s connect timeout catches dead connections fast without waiting the OS default (often 30-60s).

### Retry policy (minimal — speed over persistence)

**Autocomplete / proactive / error correction: NO retries.**
These are speculative suggestions. A retry adds latency for a suggestion that may already be stale. If the request fails, silently drop it. The user hasn't asked for anything — they won't notice the absence.

**NL command / history search: 1 retry with 500ms delay.**
The user explicitly requested these (pressed Ctrl+G or Ctrl+R) and is waiting. One fast retry covers transient blips (TCP RST, momentary packet loss). If the retry also fails, show a brief error: `aish: couldn't reach API — check your connection`.

### Circuit breaker

Prevents burning battery and CPU when the connection is clearly down. Implemented in the daemon's LLM client layer:

```
State machine:
  CLOSED (normal) → 3 consecutive failures → OPEN (tripped)
  OPEN → reject all requests instantly (no network call) for 30s
  OPEN → after 30s → HALF-OPEN (allow 1 probe request)
  HALF-OPEN → probe succeeds → CLOSED (back to normal)
  HALF-OPEN → probe fails → OPEN (restart 30s timer)
```

**Behavior per state:**

| State | Autocomplete | NL command | User sees |
|---|---|---|---|
| CLOSED | Normal | Normal | Normal ghost text |
| OPEN | Instantly returns empty | Returns error immediately: `aish: offline (retrying in Xs)` | No ghost text, NL commands fail fast |
| HALF-OPEN | 1 probe request allowed | 1 probe request allowed | If probe succeeds, back to normal |

**Why 3 failures / 30s cooldown:**
- 3 consecutive failures is enough to distinguish "connection is down" from "one bad request" (API 500, rate limit, etc.)
- 30s cooldown avoids constant probing on a dead connection. On airplane wifi, connectivity often comes and goes in ~30s cycles.
- The probe request in HALF-OPEN is a real autocomplete/proactive request (not a health check). If it succeeds, we know the connection is back AND we get a useful result.

**Separate circuit breakers per provider:**
If the user switches providers, each has its own circuit breaker state. A dead OpenAI connection shouldn't block Anthropic.

### Connection health awareness

The daemon tracks connection quality to adapt behavior:

```python
class ConnectionHealth:
    last_success_time: float      # timestamp of last successful API call
    last_failure_time: float      # timestamp of last failed API call
    consecutive_failures: int     # for circuit breaker
    avg_latency_ms: float         # rolling average of last 10 successful calls
    circuit_state: str            # CLOSED / OPEN / HALF-OPEN
```

**Adaptive behavior based on health:**
- `avg_latency_ms > 2000`: Connection is very slow — skip proactive suggestions (they'd arrive too late anyway), but still serve explicit requests (NL, history search)
- `consecutive_failures >= 3`: Circuit breaker trips — stop all network calls for 30s
- `last_success_time > 5min ago` and circuit is OPEN: Reduce probe frequency from every 30s to every 60s (battery conservation on long offline periods)

### What the user experiences on spotty wifi

| Scenario | Autocomplete | Proactive | NL command (Ctrl+G) | Error correction |
|---|---|---|---|---|
| **Normal connection** | Ghost text in 300-600ms | Ghost text in 0-300ms | Command in 1-3s | Fix in <1s |
| **Slow connection (>2s RTT)** | Ghost text in 2-3s (may feel laggy) | Skipped (too slow to be useful) | Command in 3-5s (spinner shown) | Fix in 2-3s |
| **Intermittent drops** | Some suggestions appear, some don't — silent | Same | Occasional `aish: couldn't reach API` — one retry covers most blips | Same as autocomplete |
| **Fully offline** | No ghost text (circuit breaker trips after 3 failures, <5s) | No ghost text | Instant error: `aish: offline` (no wait) | No suggestion |
| **Connection recovers** | Ghost text resumes within 30s (next circuit breaker probe) | Resumes | Works immediately on next Ctrl+G | Resumes |

**Key UX principle: the shell never hangs.** Every failure path has a bounded time cost:
- Autocomplete failure: ≤5s (timeout), then silent. After circuit breaker trips: 0ms (instant reject).
- NL command failure: ≤15s (timeout + 1 retry), then brief error message. After circuit breaker: instant error.
- No retry loops, no exponential backoff that could block for minutes.

### httpx client configuration

```python
self.client = httpx.AsyncClient(
    timeout=httpx.Timeout(
        connect=1.0,    # fast-fail on dead connections
        read=3.0,       # adjusted per request type
        write=1.0,
        pool=1.0,
    ),
    limits=httpx.Limits(
        max_connections=5,
        max_keepalive_connections=2,
    ),
    http2=True,          # multiplexing, fewer connections
    # keep-alive for connection reuse
)
```

### `aish status` shows connection health

```
$ aish status
  daemon:     running (pid 12345, uptime 2h)
  provider:   openai (gpt-4o-mini)
  connection: degraded — 2/5 recent requests failed, avg latency 1200ms
  circuit:    CLOSED (3 failures to trip)
  last success: 12s ago
```

Or when offline:
```
$ aish status
  daemon:     running (pid 12345, uptime 2h)
  provider:   openai (gpt-4o-mini)
  connection: offline — circuit breaker OPEN
  circuit:    OPEN (probe in 18s)
  last success: 4m ago
```

---

## Installation & Onboarding

### Installation methods

**Option A: pipx (recommended)**
```bash
pipx install aish
```
Installs in an isolated virtualenv with `aish` on PATH automatically. No virtualenv confusion.

**Option B: pip**
```bash
pip install aish
```
Fallback for users without pipx.

**Option C: Homebrew**
```bash
brew tap aish-shell/aish
brew install aish
```
Best experience on macOS. Manages PATH, upgrades, and Python dependency automatically.

**Option D: Manual / git clone**
```bash
git clone https://github.com/…/aish.git
cd aish && ./setup.sh
```

`setup.sh` handles dependencies and virtualenv setup for manual installs only. For pipx/pip/brew, this is handled by the package manager.

### First-run onboarding: `aish init`

After install, the user runs `aish init`, an interactive setup wizard. The CLI entry point (`bin/aish`) should also detect missing config and suggest `aish init` automatically.

**Step 1: Detect shell and print source line**
```
Detected: zsh
Add this to your ~/.zshrc:

  eval "$(aish shell-init zsh)"

Then restart your shell or run: exec zsh
```

**Step 2: Configure LLM provider (interactive)**
```
Choose your LLM provider:
  1) OpenAI (default)
  2) Anthropic

> 1

API key: sk-••••••••••••
Model for commands [gpt-4o]:
Model for autocomplete [gpt-4o-mini]:
```

Writes `~/.config/aish/config.toml`.

**Step 3: Verify connection**
```
✓ Daemon started
✓ Connected to OpenAI (gpt-4o-mini)
✓ Test completion succeeded

You're all set! Open a new shell and start typing.

  → Autocomplete appears as ghost text (accept with Tab or →)
  → Press Ctrl+G for natural language command mode
  → Run `aish status` to check daemon health
  → Run `aish config` to edit settings
```

### API key handling

Keys are loaded in priority order:
1. Environment variable (`AISH_API_KEY`) — for dotfile power users and CI
2. Config file (`~/.config/aish/config.toml`) — primary method, set by `aish init`
3. System keychain (stretch goal) — `security find-generic-password` on macOS

### First-use hint

The first time autocomplete fires after onboarding, show a one-time hint:
```
aish: ghost text suggestion (Tab to accept, → to accept word, Esc to dismiss)
```
Suppressed after first display by writing a `~/.config/aish/.onboarded` marker file.

### CLI commands

| Command | Description |
|---|---|
| `aish init` | Interactive setup wizard |
| `aish start` | Start the daemon (normally auto-started on first use) |
| `aish stop` | Stop the daemon |
| `aish status` | Show daemon health, connected provider, current models, uptime |
| `aish config` | Open config file in `$EDITOR` |
| `aish model` | Show current models for both autocomplete and NL commands |
| `aish model list` | List available models from the configured provider (queries API) |
| `aish model set <model>` | Set both autocomplete and NL model |
| `aish model set --autocomplete <model>` | Set autocomplete model only |
| `aish model set --nl <model>` | Set NL command model only |
| `aish provider` | Show current provider and endpoint |
| `aish provider set <name>` | Switch provider (`openai`, `anthropic`); prompts for API key as needed |
| `aish history` | Show recent AI interactions |
| `aish set <key> <value>` | Set any config value (e.g. `aish set autocomplete_delay_ms 500`) |
| `aish get <key>` | Show current value of a config key |
| `aish reset <key>` | Reset a config key to its default value |
| `aish defaults` | Show all config keys with current and default values |
| `aish help` | Show feature overview and all available commands |
| `aish help <command>` | Show detailed help for a specific command |

#### `aish help`

Full help screen showing features, shortcuts, and all available commands:

```
$ aish help

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
    aish model [list|set]     Show, list, or change models
    aish provider [set]       Show or change LLM provider
    aish set <key> <value>    Change a config value
    aish get <key>            Show a config value
    aish reset <key>          Reset a config key to default
    aish defaults             Show all settings with defaults
    aish config               Edit config file in $EDITOR
    aish start | stop         Manage daemon
    aish history              Recent AI interactions
    aish help [command]       This screen, or help for a command

  Run `aish help <command>` for details on any command.
```

#### In-shell cheat sheet (Ctrl+/)

A ZLE widget bound to `Ctrl+/` that shows a quick-reference overlay in `$POSTDISPLAY`. Disappears on the next keystroke without affecting `$BUFFER`:

```
$ █
  ┌─────────────────────────────────────────┐
  │  aish shortcuts                         │
  │                                         │
  │  Tab / →     Accept autocomplete        │
  │  → (word)    Accept one word            │
  │  Esc         Dismiss suggestion         │
  │  Ctrl+G      Natural language command   │
  │  Ctrl+R      Search history by intent   │
  │  Ctrl+/      This cheat sheet           │
  │                                         │
  │  Press any key to dismiss               │
  └─────────────────────────────────────────┘
```

Implementation:
- ZLE widget sets `$POSTDISPLAY` to the formatted cheat sheet text
- Next keystroke handler clears `$POSTDISPLAY` and falls through to normal input
- No daemon communication needed — purely shell-side
- Hotkey is configurable via `cheat_sheet_hotkey` (default: `Ctrl+/`)

#### Changing settings after init

Three ways to change configuration, all equivalent:

**1. CLI commands (recommended for quick changes)**
```bash
# Change any setting by key
$ aish set autocomplete_delay_ms 500
  ✓ autocomplete_delay_ms → 500

$ aish set nl_hotkey "^X"
  ✓ nl_hotkey → Ctrl+X
  ⚠ Restart your shell for hotkey changes to take effect

$ aish set error_correction false
  ✓ error_correction → false

# Check current value
$ aish get autocomplete_delay_ms
  autocomplete_delay_ms = 500 (default: 200)

# Reset to default
$ aish reset autocomplete_delay_ms
  ✓ autocomplete_delay_ms → 300 (default)

# See everything
$ aish defaults
  provider           = openai           (default: openai)
  model              = gpt-4o           (default: gpt-4o)
  autocomplete_model = gpt-4o-mini      (default: same as model)
  autocomplete_delay_ms = 200           (default: 200)
  autocomplete_delay_short_ms = 100    (default: 100)
  autocomplete_delay_threshold = 8     (default: 8)
  autocomplete_min_chars = 3            (default: 3)
  nl_hotkey          = ^G               (default: ^G)
  history_search_hotkey = ^R            (default: ^R)
  error_correction   = true             (default: true)
  proactive_suggestions = true          (default: true)
  proactive_output_lines = 50           (default: 50)
  ...
```

**2. Edit config file directly**
```bash
$ aish config   # opens ~/.config/aish/config.toml in $EDITOR
```

**3. Re-run the setup wizard**
```bash
$ aish init     # re-runs interactive setup, preserving existing values as defaults
```

All three methods write to `~/.config/aish/config.toml`. For non-hotkey changes, the CLI sends `reload_config` to the daemon for immediate effect. Hotkey changes require a shell restart since keybindings are set at shell init time.

#### Model switching UX

**Quick switch from the command line:**
```bash
# See what you're running
$ aish model
  autocomplete: gpt-4o-mini (openai)
  nl-commands:  gpt-4o (openai)

# Switch autocomplete to haiku
$ aish model set --autocomplete claude-haiku
  ✓ autocomplete model → claude-haiku

# Switch provider
$ aish provider set anthropic
  API key: sk-ant-••••••••••••
  ✓ provider → anthropic
  Model for commands [claude-sonnet]:
  Model for autocomplete [claude-haiku]:
  ✓ Ready

# Browse available models
$ aish model list
  Available models (openai):
    gpt-4o          gpt-4o-mini       gpt-4-turbo
    o1              o1-mini           o3-mini
```

**How it works under the hood:**
- `aish model set` and `aish provider set` update `~/.config/aish/config.toml` in place
- After writing config, the CLI sends a `{"type": "reload_config"}` message to the daemon over the Unix socket
- The daemon hot-reloads the config (new model, new endpoint) without restarting — no shell restart needed
- `aish model list` queries the provider's model list endpoint (`GET /v1/models` for OpenAI-compatible, Anthropic models API)

### Hotkey defaults and conflict detection

#### Default hotkeys

| Hotkey | Feature | Standard meaning in zsh | Conflict risk |
|---|---|---|---|
| **Tab** | Accept autocomplete suggestion | Native completion | Low — aish only intercepts when ghost text is visible; otherwise falls through to native Tab completion |
| **→** (right arrow) | Accept suggestion / accept word | Move cursor right | Low — only intercepted when ghost text is visible and cursor is at end of line |
| **Ctrl+G** | NL command prompt | `send-break` (abort current input) | Medium — rarely used, but some users may rely on it |
| **Ctrl+R** | NL history search | `reverse-search-history` (native reverse search) | Intentional override — aish is a strict semantic upgrade of native Ctrl+R. Users who want the old behavior can rebind via `history_search_hotkey` |
| **Ctrl+/** | Cheat sheet | Undo (in some setups) | Low — `^_` is rarely used; overlay is dismissable with any key |
| **Esc** | Dismiss ghost text | Vi mode prefix | Low — only clears `$POSTDISPLAY`, doesn't consume the keystroke in normal mode |

#### Conflict detection during `aish init`

During `aish init`, after detecting the shell, check for conflicts:

```
Checking hotkey conflicts...

  Ctrl+G (NL commands): currently bound to `send-break`
    → Override? This is rarely used. [Y/n]

  Ctrl+R (history search): overrides native reverse-search-history ✓
    aish provides a semantic upgrade — same key, smarter search

  Tab (accept suggestion): native completion preserved ✓
    aish only intercepts when ghost text is visible
```

Implementation:
- Run `bindkey "^G"` in zsh to check existing bindings
- Ctrl+R override is intentional (semantic upgrade) and is not flagged as a conflict
- If a conflict is found, explain what the existing binding does and offer alternatives
- Suggest safe alternatives: `Ctrl+]`, `Ctrl+\`, `Ctrl+X Ctrl+G` (two-key sequence)
- Store the chosen hotkeys in config; the shell integration reads them at source time

---

## LLM Provider Architecture

### Design principle: OpenAI-compatible API as the universal protocol

The LLM client (`llm.py`) uses the OpenAI-compatible `/v1/chat/completions` endpoint as the primary HTTP code path. Anthropic gets its own adapter due to its different API format. Local model support (Ollama, LM Studio, etc.) is deferred to a future phase.

```python
# One code path handles OpenAI and any OpenAI-compatible server
async def complete(self, messages: list[dict]) -> str:
    response = await self.client.post(
        f"{self.api_base_url}/chat/completions",
        json={"model": self.model, "messages": messages, "stream": True},
        headers={"Authorization": f"Bearer {self.api_key}"},
    )
```

### Supported providers

| Provider | Type | `api_base_url` | API key required | Notes |
|---|---|---|---|---|
| OpenAI | Cloud | `https://api.openai.com/v1` | Yes | Default provider |
| Anthropic | Cloud | `https://api.anthropic.com` | Yes | Separate adapter (different format) |
| Any OpenAI-compatible | Cloud | User-configured | Yes | Any compatible endpoint works |

> **Future phase: Local model support** — Ollama, LM Studio, llama.cpp, vLLM, and other local inference servers will be supported in a future phase. The OpenAI-compatible code path already handles these; the main work is optimizing prompt sizes for local model throughput and handling the no-API-key flow.

### Recommended models

| Provider | Autocomplete model | NL command model | Notes |
|---|---|---|---|
| OpenAI | `gpt-4o-mini` | `gpt-4o` | Best latency for autocomplete |
| Anthropic | `claude-haiku` | `claude-sonnet` | Prompt caching reduces repeat latency |

### Prompt caching

Both providers support caching the prompt prefix to dramatically reduce time-to-first-token on repeated requests:

- **OpenAI**: Automatic prompt caching. Requests with shared prefixes (system prompt + session context) get ~50% latency reduction on cache hit.
- **Anthropic**: Explicit cache control via `cache_control` blocks. The daemon marks the system prompt + session buffer as cacheable. On cache hit, only the new `last_output`/`buffer` tokens are processed.

The daemon structures prompts with stable prefixes first (system prompt → session buffer → history) and variable content last (current buffer / last_output) to maximize cache hit rates.

### Config example

```toml
[provider]
name = "openai"
api_key = "sk-..."
model = "gpt-4o"                    # NL command construction
autocomplete_model = "gpt-4o-mini"  # fast model for autocomplete
```

### Implementation in `llm.py`

- `OpenAIClient` — handles OpenAI and any OpenAI-compatible servers
- `AnthropicClient` — separate adapter for Anthropic's API format, with explicit `cache_control` support
- Both implement the same `async complete(messages) -> str` interface
- Factory function picks the right client based on `provider.name` in config
- Connection pooling via persistent `httpx.AsyncClient` with keep-alive
- Prompt structure for cache optimization: system prompt (stable) → session buffer (semi-stable) → history (semi-stable) → buffer/output (variable)

---

## Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Daemon language | Python 3 | Universal availability, excellent async HTTP libs, fast to develop |
| IPC mechanism | Unix domain socket | No port conflicts, fast, secure (file permissions) |
| Protocol | Newline-delimited JSON | Simple, debuggable, no dependencies |
| Ghost text | zsh `$POSTDISPLAY` | Native zsh mechanism, no terminal escape sequence hacks |
| Async in shell | `zle -F` (fd watcher) | Non-blocking, built into zsh |
| Config format | TOML | Human-readable, simple, Python stdlib support (3.11+) / tomli |

## File Structure

```
aish/
├── LICENSE                     # MIT License
├── PLAN.md
├── README.md                   # User-facing docs (install, usage, config)
├── CONTRIBUTING.md             # Contribution guidelines
├── pyproject.toml              # Python packaging (replaces setup.py)
├── .github/
│   ├── workflows/
│   │   ├── ci.yml              # Lint + test on push/PR
│   │   └── release.yml         # Publish to PyPI on tag
│   └── ISSUE_TEMPLATE/
│       ├── bug_report.md
│       └── feature_request.md
├── bin/
│   └── aish                    # CLI entry point (start/stop/status)
├── src/
│   └── aish/
│       ├── __init__.py
│       ├── daemon.py           # Main daemon (asyncio event loop, socket server)
│       ├── llm.py              # LLM API client (OpenAI, Anthropic)
│       ├── prompts.py          # System/user prompt templates
│       ├── context.py          # Context gathering and caching
│       ├── safety.py           # Command safety checks and history sanitization
│       └── config.py           # Config file parsing
├── shell/
│   ├── zsh/
│   │   ├── aish.zsh            # Main integration (source this from .zshrc)
│   │   ├── autocomplete.zsh    # ZLE autocomplete widget
│   │   └── nl-command.zsh      # ZLE natural language widget
│   ├── bash/
│   │   └── aish.bash           # Bash integration
│   └── fish/
│       └── aish.fish           # Fish integration
├── tests/
│   ├── test_daemon.py          # Daemon unit tests
│   ├── test_llm.py             # LLM client tests (mocked)
│   ├── test_prompts.py         # Prompt template tests
│   ├── test_safety.py          # Safety filter tests
│   └── test_config.py          # Config parsing tests
└── config/
    └── default.toml            # Default configuration template
```

## Implementation Order for Claude Code

1. **Phase 1 (scaffolding)** — directory structure, `pyproject.toml`, `config.py` with TOML parsing, `default.toml`, LICENSE, `aish shell-init zsh` CLI subcommand, `AISH_API_KEY` env var support
2. **Phase 2 (daemon core)** — asyncio socket server, request routing, `llm.py` with OpenAI + Anthropic clients, streaming, connection pooling, response caching with TTL, per-request-type timeouts, retry policy (none for autocomplete, 1 for NL), all prompt templates in `prompts.py`
3. **Phase 3 (autocomplete)** — ZLE ghost text widget with adaptive debounce, prefix reuse, request cancellation, proactive suggestions (output capture via exec fd redirection, heuristic pre-filter, interactive command blocklist, background prefetch during precmd), cheat sheet widget (Ctrl+/), first-use onboarding hint
4. **Phase 4 (NL command)** — Ctrl+G widget, inline `aish>` prompt, partial buffer context, spinner, undo with Ctrl+Z
5. **Phase 4b (error correction)** — precmd hook, stderr capture, error correction ghost text, priority over proactive suggestions
6. **Phase 4c (NL history search)** — Ctrl+R widget (replaces native reverse search), fzf-style result list, semantic ranking, history sanitization
7. **Phase 5 (context enrichment)** — rolling session buffer (20 cmds × 20 lines), prompt caching (OpenAI auto-cache, Anthropic explicit `cache_control`), cwd/git/env context gathering, context cache in daemon
8. **Phase 7 (safety/polish)** — dangerous command warnings, history/output sanitization, circuit breaker (CLOSED/OPEN/HALF-OPEN), connection health tracking, `aish status` with health display, `aish init` wizard with hotkey conflict detection, config hot-reload via socket, full CLI command set (model/provider/set/get/reset/defaults/help), README.md, CONTRIBUTING.md
9. **Phase 8 (Homebrew + CI)** — Homebrew tap repo, formula, CI auto-update on release, GitHub Actions `ci.yml` (lint/typecheck/test) and `release.yml` (PyPI publish)
10. **Phase 6b (bash/fish)** — port ZLE widgets to readline/fish keybindings
11. **Phase 6 (local models)** — add local model support (Ollama, LM Studio, etc.) after cloud is solid

Write tests alongside each phase (tests/ directory mirrors src/). Each phase should be fully functional and testable before moving to the next.

---

## Open Source Readiness Checklist

- [ ] MIT LICENSE file in repo root
- [ ] README.md with: project description, install instructions (pip/brew/manual), usage guide, config reference, supported terminals list, GIF/screenshot demo
- [ ] CONTRIBUTING.md with: dev setup, code style, PR process, issue guidelines
- [ ] pyproject.toml for `pip install aish` (published to PyPI)
- [ ] GitHub Actions CI: lint (ruff), type check (mypy), tests (pytest)
- [ ] GitHub Actions release: auto-publish to PyPI on version tag
- [ ] Homebrew tap (`homebrew-aish`) with formula and CI auto-update on release
- [ ] No terminal-specific branding — works with any modern terminal
- [ ] API keys never logged, never committed, loaded from config file or env var only
- [ ] All LLM calls clearly documented in privacy section of README (what data is sent, what isn't)
