# Autocomplete — User Flow

## Scenario 1: Simple command completion

```
# User starts typing a git command
$ git sta█

# After 200ms pause, ghost text appears (dimmed/grey)
$ git sta‹tus --short›

# User presses Tab or → to accept the full suggestion
$ git status --short█

# Or presses → once to accept one word at a time
$ git status█ ‹--short›
```

## Scenario 2: Context-aware completion

```
# User is in a git repo with unstaged changes
$ git █

# Ghost text suggests based on repo state (unstaged files detected)
$ git ‹add -p›

# User ignores it and keeps typing — ghost text clears instantly
$ git co█

# New suggestion appears after 200ms pause
$ git co‹mmit -m ""›
```

## Scenario 3: Path and argument completion

```
# User is in a project directory with src/, tests/, docs/
$ python █

# LLM sees cwd contents and recent history (user was editing tests)
$ python ‹-m pytest tests/›

# User types something else — ghost text clears
$ python src/█

# New suggestion based on directory contents
$ python src/‹main.py›
```

## Scenario 4: Multi-command / pipe completion

```
# User starts a pipeline
$ cat access.log | grep 404 | █

# LLM suggests a useful continuation
$ cat access.log | grep 404 | ‹awk '{print $7}' | sort | uniq -c | sort -rn›

# Tab to accept all, or → to accept word by word
```

## Scenario 5: No suggestion warranted

```
# User types something too ambiguous (1 character)
$ a█
# Nothing happens — below autocomplete_min_chars threshold

# User types a complete command, nothing useful to add
$ ls█
# No ghost text — LLM returns empty (nothing to add)

# User is mid-path where filesystem completion is better
$ cd ~/Docu█
# ghst stays quiet — native zsh completion handles this better
```

## Scenario 6: Proactive suggestion — explicit command in output

```
# User finishes a copilot session. The output ends with:
#   Total session time:     20s
#   Resume this session with copilot --resume=64a11e60-0fe6-4517-9e1b-3675ac2cccf2

# Fresh prompt appears with ghost text IMMEDIATELY (before typing anything)
$ ‹copilot --resume=64a11e60-0fe6-4517-9e1b-3675ac2cccf2›

# Tab or → to accept, then Enter to run
$ copilot --resume=64a11e60-0fe6-4517-9e1b-3675ac2cccf2█

# Or start typing something else — ghost text clears instantly
$ vim█
```

## Scenario 7: Proactive suggestion — general next-command prediction

```
# User runs git push, it fails with a helpful message:
#   fatal: The current branch feature/auth has no upstream branch.
#   To push the current branch and set the remote as upstream, use
#       git push --set-upstream origin feature/auth

# Fresh prompt shows ghost text with the suggested fix
$ ‹git push --set-upstream origin feature/auth›

# Another example: user runs npm install, output mentions audit issues:
#   found 3 vulnerabilities (1 moderate, 2 high)
#   run `npm audit fix` to fix them

$ ‹npm audit fix›

# Another: git status shows merge conflicts
#   both modified:   src/main.py

$ ‹git mergetool›

# Another: pytest finishes with failures
#   FAILED tests/test_auth.py::test_login - AssertionError

$ ‹pytest tests/test_auth.py::test_login -x›
```

## Scenario 8: Proactive suggestion with session-level awareness

```
# User has been debugging merge conflicts across several commands:
$ git status
#   both modified:   src/main.py
#   both modified:   src/auth.py

$ cat src/main.py
# <<<<<<< HEAD
# def login(user):
# =======
# def login(user, remember=False):
# >>>>>>> feature/auth

$ grep "<<<" src/*.py
# src/main.py:<<<<<<< HEAD
# src/auth.py:<<<<<<< HEAD

# Now the prompt is empty. The LAST command's output (grep) just shows
# file names — not obviously actionable on its own. But the daemon's
# rolling session buffer has all 3 commands + outputs, so it knows
# the user is resolving merge conflicts.

# Ghost text appears:
$ ‹git mergetool›

# Without session context, the LLM would only see "src/main.py:<<<<<<< HEAD"
# and might not suggest anything useful. With the full session buffer,
# it understands the user's intent.
```

## Scenario 9: Proactive suggestion skipped (heuristic says no)

```
# User runs `ls` — short, routine command, output is just a file listing
# Heuristic pre-filter finds nothing actionable → no LLM call, no ghost text
$ █

# User runs `cat README.md` — output is file contents, nothing actionable
$ █

# User runs a long build that succeeds with "BUILD SUCCESSFUL"
# Heuristic scans output, finds no command suggestions → no ghost text
$ █
```

## What happens under the hood (proactive suggestions) — NOT YET IMPLEMENTED

> **Status**: The daemon-side infrastructure exists (session buffer, proactive prompt,
> `_handle_complete` detects proactive mode when `buffer=""` and `last_output` is present),
> but the shell-side output capture is not implemented. See "Output capture mechanism" below.
> Currently `preexec` only records the command name and `precmd` records exit status — no
> output is captured or sent to the daemon.

### Planned flow (when output capture is available)

```
Previous command finishes
  │
  ▼
precmd hook fires (BEFORE prompt is drawn)
  ├── Read captured output (last 50 lines from temp file)
  ├── Strip ANSI escape codes
  ├── Run heuristic pre-filter on output:
  │   ├── Scan for command-like patterns:
  │   │   ├── Lines starting with $, >, or common commands
  │   │   ├── Phrases like "run", "try", "use", "resume with", "fix with"
  │   │   ├── Backtick-quoted or code-fenced commands
  │   │   ├── Non-zero exit status (always qualifies)
  │   │   └── Known tool patterns (git upstream, npm audit, etc.)
  │   ├── Match found → continue to daemon request
  │   └── No match → skip (no API call, no ghost text)
  │
  ▼
BACKGROUND PREFETCH: send request to daemon DURING precmd
(daemon starts LLM inference while zsh is still rendering the prompt)
{
  "type": "complete",
  "request_id": "pro-xyz789",
  "buffer": "",
  "cursor_pos": 0,
  "cwd": "/home/matt/project",
  "shell": "zsh",
  "history": ["copilot", "cd project", "git status", ...],
  "exit_status": 0,
  "last_command": "copilot",
  "last_output": "...\nResume this session with copilot --resume=64a11e60-..."
}
  │
  ▼
zle -F registers fd watcher (prompt is interactive immediately)
  │
  ▼
Daemon receives request
  ├── Detects proactive mode: buffer is empty + last_output is present
  ├── Appends (last_command, last_output) to rolling session buffer
  ├── Builds prompt with TWO tiers of context:
  │   ├── Tier 1 — Per-command output (from this request's last_output)
  │   │   Primary signal. The raw last 50 lines of the most recent command.
  │   │   Covers explicit "try this" messages, error output, tool suggestions.
  │   └── Tier 2 — Rolling session buffer (from daemon memory)
  │       Last ~20 commands + truncated outputs (20 lines each).
  │       Gives session-level awareness. Example prompt context:
  │       ┌──────────────────────────────────────────────────┐
  │       │ Recent session:                                  │
  │       │ [3] git status                                   │
  │       │     → 2 files with merge conflicts               │
  │       │ [2] cat src/main.py                              │
  │       │     → (file contents with <<<<<<< markers)       │
  │       │ [1] grep "<<<" src/main.py                       │
  │       │     → 3 conflict markers found                   │
  │       │                                                  │
  │       │ Current command output (last 50 lines):          │
  │       │     (full last_output from this request)         │
  │       └──────────────────────────────────────────────────┘
  │       No RAG needed — fits in-context (128k+ tokens).
  │       Buffer is ephemeral (daemon memory, lost on restart).
  ├── PROMPT CACHING: prompt is structured for maximum cache hits:
  │   ├── [cacheable prefix] system prompt → stable, rarely changes
  │   ├── [cacheable prefix] session buffer → semi-stable, grows slowly
  │   ├── [variable suffix] last_output → changes every request
  │   └── On Anthropic: explicit cache_control markers on prefix blocks
  │       On OpenAI: automatic prefix caching (no code changes needed)
  │       Cache hit → ~50% faster time-to-first-token
  ├── Uses autocomplete model (fast) with proactive prompt:
  │   "Given this terminal session context and the latest command output,
  │    suggest the single most likely next command the user would want to
  │    run. Return ONLY the command. Return empty string if nothing is
  │    clearly suggested."
  ├── Cache key: (last_command, cwd, output_hash)
  └── Response: {"type": "complete", "request_id": "pro-xyz789",
                  "suggestion": "copilot --resume=64a11e60-..."}
  │
  ▼
zle -F callback fires
  ├── Check: is request_id still current? (user may have started typing)
  │   ├── Stale → discard
  │   └── Current → store suggestion in __GHST_SUGGESTION, draw ghost text
  └── zle reset-prompt
  │
  ▼
User sees: $ ‹copilot --resume=64a11e60-...›
  │
  ▼
Same accept/dismiss behavior as regular autocomplete:
  ├── Tab or →     → accept into $BUFFER
  ├── Any other key → clear ghost text, normal typing
  └── Esc           → dismiss
```

### Why not RAG?

The terminal session is a sequential stream — the most relevant context is always recent. A rolling buffer of ~20 commands × 20 lines of output is ~2k lines, which fits trivially in modern LLM context windows (128k+ tokens). RAG would add an embedding model, a vector store, and chunking logic for no practical benefit. If session context ever grows beyond what fits in-context (very long multi-hour sessions), we truncate the oldest entries from the circular buffer — the user's recent actions are what matter most.

## What happens under the hood (regular autocomplete)

### Ghost text rendering: direct terminal escape codes

Ghost text is drawn by writing ANSI escape codes directly to `/dev/tty`, bypassing ZLE's
rendering pipeline entirely. This is the only approach that works reliably on zsh 5.9 (macOS):

- **POSTDISPLAY**: Does NOT interpret ANSI escape sequences — `\e[90m` renders as raw text.
  The `region_highlight` `P` prefix with `fg=242` was invisible (possibly terminal-dependent).
- **BUFFER modification from `zle -F` callbacks**: `$BUFFER` reads as empty inside async
  fd-watcher callbacks on zsh 5.9 macOS. This is a fundamental limitation that makes any
  BUFFER-based approach (like zsh-autosuggestions) unworkable from async contexts.
- **What works**: `echo -n $'\e[90m'$suggestion$'\e[0m\e[${len}D' > /dev/tty` — prints
  gray text at the cursor, then moves the cursor back. The ghost text is purely visual
  (not in BUFFER), so accepting it means appending `$__GHST_SUGGESTION` to `$BUFFER`.

### IPC: native zsh sockets via `zsh/net/socket`

Communication with the daemon uses zsh's built-in `zsocket` command (from `zsh/net/socket`),
which connects directly to the Unix domain socket without spawning any external process:

```zsh
zmodload zsh/net/socket
zsocket "$__GHST_SOCKET"          # $REPLY = fd number
print -u $REPLY "$json_request"   # send
zle -F $REPLY __ghst_on_response  # watch for response async
```

This avoids the overhead of spawning `python3` or `socat` per keystroke. The `zle -F` callback
fires when data arrives on the socket fd, reads the JSON response, extracts the suggestion,
and calls `__ghst_draw_ghost` — all without modifying BUFFER.

### Debounce: process substitution timer

Debounce uses `exec {fd}< <(sleep $delay && echo fire)` with `zle -F` to watch the fd.
When the sleep completes and writes "fire", the callback sends the autocomplete request.
Each new keystroke cancels the previous timer fd and starts a new one.

This replaces `sched` (which doesn't work reliably for sub-second delays in ZLE context)
and avoids external timer processes.

### Full flow

```
Keystroke ('a')
  │
  ▼
__ghst_self_insert (ZLE widget, bound to all printable chars via range binding)
  ├── __ghst_clear_suggestion()
  │   ├── echo -n '\e[0K' > /dev/tty  (erase ghost text from terminal)
  │   └── __GHST_SUGGESTION=""
  ├── zle .self-insert (normal character insertion into BUFFER)
  └── __ghst_schedule_complete()
        │
        ▼
  __ghst_schedule_complete()
  ├── Cancel any existing debounce timer: zle -F $timer_fd; exec {fd}<&-
  ├── ${#BUFFER} < __GHST_MIN_CHARS (3)? → return (skip)
  ├── Prefix reuse check:
  │   └── If BUFFER extends LAST_BUFFER and SUGGESTION starts with the extra chars,
  │       trim SUGGESTION and redraw — no API call needed
  ├── Adaptive debounce:
  │   ├── ${#BUFFER} < 8 → delay = 200ms
  │   └── ${#BUFFER} >= 8 → delay = 100ms
  └── exec {timer_fd}< <(sleep $delay && echo fire)
      zle -F $timer_fd __ghst_debounce_fired
        │
        ▼ (after debounce expires)
  __ghst_debounce_fired()
  ├── Clean up timer fd
  └── __ghst_send_request "$BUFFER" "$CURSOR"
        │
        ▼
  __ghst_send_request()
  ├── Close any previous in-flight response fd
  ├── zsocket "$__GHST_SOCKET" → $REPLY = fd
  ├── Build JSON (python3 for proper escaping):
  │   {"type":"complete", "request_id":"ac-$RANDOM",
  │    "buffer":"git sta", "cursor_pos":7,
  │    "cwd":"/Users/matt/project", "shell":"zsh",
  │    "history":[], "exit_status":0}
  ├── print -u $fd "$json"
  └── zle -F $fd __ghst_on_response
        │
        ▼
  Daemon receives request
  ├── Checks cache: (buffer, cwd) → cache hit? Return immediately
  ├── Cache miss → call LLM API (autocomplete_model, non-streaming)
  │   ├── Prompt: system prompt + buffer + cwd + history + exit_status
  │   └── Instruction: "Return ONLY the completion suffix — the exact text
  │       to append directly after what they typed. Include a leading space
  │       if one is needed."
  ├── Post-processing:
  │   ├── _ensure_leading_space() — adds space before -|>&;<() if needed
  │   ├── _strip_code_fences() — regex to unwrap ```...``` blocks
  │   └── Reject multiline (take first line only)
  └── Response: {"type":"complete", "request_id":"ac-12345",
                  "suggestion":" clone https://github.com/..."}
        │
        ▼
  __ghst_on_response() — zle -F callback
  ├── read -r -u $fd response (JSON)
  ├── Clean up fd: zle -F $fd; exec {fd}<&-
  ├── Extract suggestion via shell string ops (no jq/python needed):
  │     suggestion="${response#*\"suggestion\": \"}"
  │     suggestion="${suggestion%%\"*}"
  ├── Validate: non-empty, < 200 chars, no backticks/newlines/prose
  ├── __GHST_SUGGESTION="$suggestion"
  └── __ghst_draw_ghost()
        │
        ▼
  __ghst_draw_ghost()
  └── echo -n $'\e[90m'"$suggestion"$'\e[0m\e['"${#suggestion}"'D' > /dev/tty
      (gray text at cursor → move cursor back → ghost visible, cursor unmoved)
        │
        ▼
  User sees: $ git sta‹tus --short›
        │
        ▼
  Next keystroke:
  ├── → (right arrow) → __ghst_accept_suggestion: BUFFER+=$SUGGESTION, CURSOR=end
  ├── Shift+→         → __ghst_accept_word: accept first word, redraw rest as ghost
  ├── Tab              → accept if suggestion exists, else native zsh completion
  ├── Enter            → __ghst_line_finish: clear ghost, cancel debounce, accept-line
  ├── Backspace        → clear ghost, delete char, reschedule if len >= min_chars
  └── Any printable    → clear ghost, insert char, restart debounce cycle
```

## Output capture mechanism (for proactive suggestions) — DEFERRED

> **Status**: Not implemented. The FIFO/tee approach described below was too invasive
> on macOS zsh 5.9 — it created background processes that leaked job notifications
> (`[1] done`, `[2] done`) on every command, and broke `exec zsh`. The mechanism was
> removed entirely. Proactive suggestions require a non-invasive output capture approach
> (e.g. script(1) wrapper, `REPORTTIME`-style hooks, or terminal multiplexer integration).
>
> Currently, `preexec` records the last command and `precmd` records the exit status.
> The daemon's session buffer and proactive prompt infrastructure exist but have no
> output data to feed them.

### Original design (preserved for future reference)

```
Shell startup (source ghst.zsh)
  └── Set up preexec/precmd/zshexit hooks for output capture

preexec fires (command is about to execute)
  ├── Check blocklist: is this command interactive? (vim, less, top, etc.)
  │     ├── Yes → skip capture, leave fds alone
  │     └── No → capture active
  ├── Create temp file: /tmp/ghst-out-$$.XXXXXX
  ├── Save original fds: exec {__GHST_STDOUT_BAK}>&1 {__GHST_STDERR_BAK}>&2
  ├── Create two FIFOs: /tmp/ghst-fo-$$.XXXXXX and /tmp/ghst-fe-$$.XXXXXX
  ├── Start background tee processes with PID tracking:
  │     tee -a "$file" < "$fifo_out" >&$__GHST_STDOUT_BAK &
  │     __GHST_TEE_OUT_PID=$!
  │     tee -a "$file" < "$fifo_err" >&$__GHST_STDERR_BAK &
  │     __GHST_TEE_ERR_PID=$!
  ├── Redirect stdout/stderr to FIFOs:
  │     exec > "$fifo_out" 2> "$fifo_err"
  ├── Unlink FIFOs (open fds keep them alive)
  └── Store command name: __GHST_LAST_CMD="$1"

Command runs normally (user sees all output in real time via tee)

precmd fires (command finished, prompt about to draw)
  ├── Restore original fds:
  │     exec 1>&$__GHST_STDOUT_BAK 2>&$__GHST_STDERR_BAK
  │     exec {__GHST_STDOUT_BAK}>&- {__GHST_STDERR_BAK}>&-
  ├── Kill and wait tee processes (prevents leaking):
  │     for _pid in $__GHST_TEE_OUT_PID $__GHST_TEE_ERR_PID; do
  │         kill -0 $_pid && kill $_pid; wait $_pid
  │     done
  ├── Read last 50 lines of temp file
  ├── Strip ANSI escape codes (sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')
  ├── Delete temp file
  ├── Run heuristic pre-filter on captured output
  │     ├── Match → send proactive complete request to daemon
  │     └── No match → skip, continue to normal prompt
  └── Normal precmd continues (error correction check, etc.)

zshexit fires (shell is exiting)
  └── Kill any remaining tee processes, remove temp files
```

### Why FIFOs instead of process substitution?

The original approach used `exec > >(tee ...) 2> >(tee ... >&2)`. Process substitutions create background processes with no PID tracking. When child processes hold the pipe open (e.g., background jobs), the tee processes never receive EOF and leak indefinitely. This caused orphaned tee processes to accumulate (40+ observed), eventually exhausting file descriptors and creating broken pipes that silently swallowed stderr — making "command not found" errors disappear.

FIFOs with explicit background tee (`tee < fifo &; pid=$!`) give us `$!` for PID tracking. In `precmd`, we `kill` and `wait` each tee by PID, guaranteeing cleanup regardless of child process state.

### Interactive command blocklist

Commands that use raw terminal mode, alternate screen, or expect direct TTY access. Output capture is skipped entirely for these:

```
vim, nvim, vi, nano, emacs, pico         # editors
less, more, most, bat                     # pagers
top, htop, btop, glances                  # monitors
tmux, screen                              # multiplexers
ssh, mosh                                 # remote shells
python, ipython, node, irb, ghci          # REPLs (bare, no script arg)
fzf, sk                                   # fuzzy finders
man, info                                 # help viewers
watch                                     # repeated execution
```

The blocklist is configurable via `proactive_capture_blocklist` in config. Matching is done on the first word of the command (before arguments).

### Heuristic pre-filter

A fast shell-side regex scan that decides whether the output is worth sending to the LLM. This avoids unnecessary API calls for routine commands like `ls`, `cat`, `echo`:

| Pattern | Examples |
|---|---|
| Non-zero exit status | Always qualifies — something went wrong |
| Lines containing `run `, `try `, `use `, `resume `, `execute ` | "run `npm audit fix` to fix them" |
| Lines containing backtick-quoted commands | "To fix, run \`git pull --rebase\`" |
| Lines starting with `$` or `>` followed by a command | "  $ git push --set-upstream origin main" |
| Lines starting with common command prefixes after whitespace | "    git push --set-upstream origin feature/auth" |
| Known tool patterns: `--set-upstream`, `audit fix`, `--resume=` | Tool-specific follow-up suggestions |
| Lines containing URLs with executable context | "Install from https://..." (less common) |
| Output contains "fix", "resolve", "install", "update", "upgrade" | General action words suggesting a follow-up |

If none of these patterns match, the output is considered routine and no proactive request is sent. The heuristic is intentionally loose — false positives are cheap (LLM returns empty), false negatives miss suggestions.

## Performance pipeline

### Regular autocomplete (implemented)

```
Keystroke → Adaptive debounce (200ms or 100ms)
    → Min chars check → zsocket connect (<1ms) → JSON send
    → Daemon cache check (<1ms)
    → LLM API call (200-500ms cloud, prompt cache hit: 100-250ms)
    → Response via zle -F fd watcher → ghost text render to /dev/tty (<1ms)

Total perceived latency: debounce + model inference time
Target: ghost text appears within 300-600ms of pause
```

### Proactive suggestions (not yet implemented — needs output capture)

```
Command finishes → precmd fires → Heuristic check (<1ms)
    → BACKGROUND PREFETCH: socket send during precmd (<1ms)
    → Prompt draws → user sees prompt → Daemon still processing...
    → LLM API call (200-500ms, prompt cache hit: 100-250ms)
    → Response via zle -F → ghost text render (<1ms)

Perceived latency: 0ms (prefetch started before prompt drew)
    to ~300ms (if inference takes longer than prompt render)
Best case: ghost text appears WITH the prompt (zero delay)
```

### Latency optimizations at each stage

| Stage | Optimization |
|---|---|
| Keystroke → request | Adaptive debounce (200ms base, 100ms for long buffers); cancel stale in-flight requests via fd cleanup |
| IPC | `zsocket` (native zsh socket) — no subprocess spawn per request |
| Request → daemon | Unix socket IPC, <1ms |
| Daemon → LLM | HTTP/2 connection pooling (skip TLS handshake), small prompt token budget |
| Prompt prefix | Prompt caching (OpenAI auto-cache, Anthropic explicit `cache_control: ephemeral` + beta header) — ~50% TTFT reduction on cache hit |
| LLM inference | Small/fast cloud model (`gpt-4o-mini`, `claude-haiku-4-5`), non-streaming |
| Response → display | `zle -F` fd watcher, no polling; direct `/dev/tty` write |
| Repeat requests | Response cache on `(buffer, cwd)`, ~60s TTL |
| User types more | Prefix reuse — trim existing suggestion client-side, no new API call |
| Post-processing | `_strip_code_fences()` regex, `_ensure_leading_space()`, multiline rejection |

## LLM tuning for autocomplete quality

Three parameters significantly affect the quality and verbosity of autocomplete suggestions:

1. **`temperature: 0.3`** (not 0) — Zero temperature makes the model maximally deterministic, always picking the single highest-probability next token. For `ffmpeg`, that's just `-i`. At 0.3, the model is willing to generate a fuller, more useful completion like `-i input.mp4 -c:v libx264 output.mp4`. Higher values (>0.5) risk hallucinated flags and inconsistent suggestions.

2. **Unquoted buffer in prompt** (`The user has typed: ffmpeg`, not `'ffmpeg'`) — Python's `!r` repr-quoting wraps the buffer in quotes, signaling to the LLM that it's a complete string literal rather than a partial command mid-typing. Without quotes, the LLM treats it as an incomplete command line and is more likely to continue it substantively.

3. **`max_tokens: 200`** (not 1024) — Tighter limit matches the use case (completions are short) and prevents the model from rambling if it goes off the rails. 200 tokens is plenty for even complex pipeline completions.

## Key UX decisions

| Decision | Choice | Why |
|---|---|---|
| Ghost text style | Dimmed/grey via ANSI escape codes (`\e[90m`) written directly to `/dev/tty` | Only approach that works on zsh 5.9 macOS — POSTDISPLAY doesn't interpret ANSI, BUFFER is empty in `zle -F` callbacks |
| IPC mechanism | `zsh/net/socket` (`zsocket`) — native zsh Unix socket | No subprocess per keystroke; fd integrates directly with `zle -F` async watchers |
| Accept full suggestion | → (right arrow) or Tab | Matches Fish, GitHub Copilot conventions; Tab falls back to native completion |
| Accept word-by-word | Shift+→ (right arrow) | Lets user cherry-pick parts of a suggestion |
| Dismiss | Any non-accept key clears ghost text | Typing clears ghost text and starts a new cycle; no explicit Esc binding needed |
| Debounce | `exec {fd}< <(sleep $delay && echo fire)` + `zle -F` | Process substitution timer avoids `sched` limitations; fd integrates with ZLE event loop |
| Debounce timing | 200ms base / 100ms for long buffers (all configurable) | Adaptive — `__GHST_DELAY`, `__GHST_DELAY_SHORT`, `__GHST_DELAY_THRESHOLD` |
| Min chars | 3 (configurable via `__GHST_MIN_CHARS`) | Single-char suggestions are rarely useful |
| Proactive on empty buffer | Planned but output capture not yet implemented | Requires non-invasive output capture (FIFO/tee approach was too invasive) |
| Completion spacing | `_ensure_leading_space()` in daemon for `-\|>&;<()` chars | LLMs sometimes omit leading spaces; heuristic adds them for flag/operator tokens |
| Code fence removal | `_strip_code_fences()` regex in daemon | LLMs sometimes wrap responses in \`\`\`...\`\`\` blocks; regex unwraps them |
| Prompt caching | Anthropic `cache_control: {"type": "ephemeral"}` on system prompt | ~50% TTFT reduction on cache hit; system prompt is stable across requests |
| Prefix reuse | Client-side: trim existing suggestion when user types matching chars | Avoids redundant API calls when user types into an existing suggestion |
| JSON construction | `python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'` for buffer/cwd | Proper escaping of special characters; spawned only when debounce fires (not per keystroke) |
| Daemon reload | Auto-restart when `.py` source files change | Shell checks mtimes vs PID file every 30 commands; seamless development |
| Timeout | 1s connect + 3s read hard cutoff | Fast-fail on dead connections; don't wait the OS default 30-60s |
| Failure mode | Silent — no ghost text, no error | Never interrupt the user's typing flow |
| Network down | Circuit breaker trips after 3 consecutive failures | Stops all network calls for 30s, then probes. No battery drain. |

## Edge cases

### Regular autocomplete
- **Rapid typing** — Each keystroke cancels the previous request. Only the final pause triggers a call. User never sees stale suggestions.
- **Slow response arrives after user moved on** — `request_id` check discards it silently.
- **Daemon not running** — Socket connect fails, no ghost text appears, no error shown. Shell works normally.
- **Empty suggestion from LLM** — Nothing shown. This is correct behavior (LLM is unsure).
- **Suggestion contains dangerous command** — Still shown as ghost text (it's just a suggestion), but if accepted and Enter is pressed, safety check in daemon could warn.
- **Terminal doesn't support dim text** — Fall back to a different ANSI attribute (italic, or a comment-style `# suggestion` after cursor).
- **Multi-line buffer** — Ghost text is drawn after the cursor position on the current line.

### Network failures and spotty connections
- **API timeout** — 1s connect + 3s read timeout. Dead connections fail in ≤1s (not the OS default 30-60s). No retry for autocomplete — silently dropped.
- **Circuit breaker tripped (offline)** — After 3 consecutive failures, all autocomplete/proactive requests are instantly rejected (0ms, no network call) for 30s. Then a single probe request tests the connection. If it succeeds, normal operation resumes. If not, another 30s cooldown.
- **Intermittent drops** — Some requests succeed, some fail. The user sees suggestions sometimes, nothing other times. No error messages. Circuit breaker only trips on 3 _consecutive_ failures, so intermittent drops don't trigger it.
- **Very slow connection (>2s RTT)** — Autocomplete suggestions arrive late but are still shown if the `request_id` is current. Proactive suggestions are skipped when `avg_latency > 2s` (they'd arrive too late to be useful). NL commands still work (user is waiting explicitly).
- **Connection recovers after offline** — Circuit breaker enters HALF-OPEN after 30s, sends one probe. On success, immediately returns to CLOSED (normal). Worst case: 30s gap between connection recovery and first suggestion.
- **Mid-request disconnect** — httpx raises on read timeout (3s). Request is silently dropped. No partial response handling needed — streaming responses that die mid-stream are treated as failures.
- **DNS failure** — Caught by the 1s connect timeout. Same path as any connection failure.
- **API rate limit (429)** — Treated as a failure for circuit breaker purposes. The daemon respects `Retry-After` headers if present, but does NOT retry autocomplete requests.
- **API server error (500/502/503)** — Same as timeout: silent drop for autocomplete, one retry for NL commands.

### Proactive suggestions
- **User starts typing before proactive response arrives** — `request_id` check discards the proactive suggestion. Regular autocomplete takes over.
- **Both proactive and error correction fire** — Error correction takes priority (it fires for non-zero exit). Proactive suggestions are suppressed when error correction is active.
- **Output capture breaks an interactive program** — Blocklist prevents capture for known interactive commands. If an unlisted program misbehaves, user can add it to `proactive_capture_blocklist` in config.
- **Very long output (>1000 lines)** — Only the last 50 lines are captured for Tier 1 (per-command). The rolling session buffer stores only the last 20 lines per command, so even verbose output doesn't bloat the session context.
- **Output contains sensitive data** — Same sanitization as history (strip lines matching password/token/secret patterns) before sending to LLM. Applied to both per-command output and session buffer entries.
- **Temp file cleanup** — If the shell exits abnormally (kill -9), orphaned temp files are cleaned up on next startup via a glob on `/tmp/ghst-out-*.XXXXXX`.
- **Heuristic false negative** — Occasionally misses an actionable output. Acceptable tradeoff — the heuristic is tuned for recall over precision, and the cost of a miss is just "no suggestion shown."
- **Piped commands** — For pipelines (`cmd1 | cmd2`), only the final command's output is captured. This is correct behavior — the final output is what the user sees.
- **Session buffer overflow** — Circular buffer drops oldest entries when it exceeds 20 commands. Most relevant context is recent; old commands rarely matter for proactive suggestions.
- **Daemon restart clears session buffer** — By design. Session context is ephemeral — a fresh daemon has no memory of previous commands. This is acceptable: proactive suggestions degrade gracefully to Tier 1 only (per-command output) until the buffer re-accumulates.
- **Heuristic says skip but session buffer has rich context** — The heuristic only gates the LLM call. If it skips, the output is still NOT added to the session buffer (no request was sent to the daemon). This means routine commands like `ls` don't pollute the session buffer, keeping it high-signal.
