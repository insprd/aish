# Natural Language Command Construction — User Flow

## Scenario 1: Empty prompt, simple request

```
# User is at a normal zsh prompt, presses Ctrl+G
$ █

# Prompt changes to an inline NL input
shai> █

# User types their intent in plain English
shai> find all python files larger than 1mb modified in the last week█

# User presses Enter — spinner appears
shai> find all python files larger than 1mb modified in the last week
  ⠋ thinking...

# Generated command replaces the prompt (highlighted briefly to show it's AI-generated)
$ find . -name "*.py" -size +1M -mtime -7█

# User is now at a normal prompt with the command in their buffer.
# They can:
#   Enter  → execute it
#   Edit   → modify it first, then Enter
#   Ctrl+C → cancel, clear the line
#   Ctrl+Z → undo, restore whatever was in the buffer before
```

## Scenario 2: Partial buffer as context

```
# User started typing but isn't sure of the flags
$ docker run -v █

# Presses Ctrl+G — existing buffer is preserved as context
shai> (docker run -v ...) mount current dir as /app and run node█

# Enter → thinking...
shai> (docker run -v ...) mount current dir as /app and run node
  ⠋ thinking...

# LLM sees both the partial command AND the natural language description
# It completes/replaces intelligently:
$ docker run -v $(pwd):/app -w /app node:20 node█
```

## Scenario 3: Multi-step refinement

```
# First generation
$ awk '{print $3}' access.log | sort | uniq -c | sort -rn | head -20█

# User thinks "close but I want IPs only from today"
# Presses Ctrl+G again
shai> (awk '{print $3}' ...) only include lines from today's date█

# LLM refines the existing command:
$ grep "$(date +%d/%b/%Y)" access.log | awk '{print $3}' | sort | uniq -c | sort -rn | head -20█
```

## What happens under the hood

```
Keystroke (Ctrl+G)
  │
  ▼
ZLE widget activates
  ├── Saves current $BUFFER to $SHAI_SAVED_BUFFER
  ├── Replaces prompt with "shai> "
  ├── If buffer had content, shows it as "(partial cmd...) " prefix
  └── Enters recursive-edit mode for NL input
        │
        ▼
  User types description + Enter
        │
        ▼
  ZLE widget sends request to daemon via Unix socket:
  {
    "type": "nl",
    "prompt": "find all python files larger than 1mb modified in the last week",
    "buffer": "",              ← existing partial command (if any)
    "cwd": "/home/matt/project",
    "shell": "zsh",
    "history": ["git status", "cd project", "ls -la", ...]
  }
        │
        ▼
  Shows spinner in $POSTDISPLAY via zle -F (non-blocking)
        │
        ▼
  Daemon receives request
  ├── Builds prompt with context (cwd, history, partial buffer, OS)
  ├── Calls LLM API (2s connect + 12s read timeout, not streaming — we need the full command)
  │   └── On failure: 1 retry with 500ms delay (user is waiting explicitly)
  └── Returns: {"type": "nl", "command": "find . -name '*.py' -size +1M -mtime -7"}
        │
        ▼
  ZLE widget receives response
  ├── Sets $BUFFER to the generated command
  ├── Restores normal prompt (PS1)
  ├── Positions cursor at end of command
  ├── Brief highlight (ANSI color for ~1s) to signal "this is AI-generated"
  └── Waits for user action (Enter / edit / Ctrl+C / Ctrl+Z)
```

## Key UX decisions

| Decision | Choice | Why |
|---|---|---|
| Never auto-execute | Always | Safety — user must press Enter to run |
| Inline prompt vs popup | Inline (`shai>` replaces `$`) | Stays in flow, no mode switch |
| Partial buffer handling | Send as context to LLM | User's partial typing is valuable signal |
| Ctrl+Z undo | Restore original `$BUFFER` | Easy to bail out |
| Timeout | 15s total (2s connect + 12s read) | NL commands are more complex, user expects a pause |
| Retry | 1 retry with 500ms delay | User is waiting explicitly — cover transient blips |
| Spinner | `$POSTDISPLAY` with `zle -F` | Non-blocking, disappears cleanly |
| Visual indicator | Brief color flash on generated command | Makes it obvious this wasn't typed |

## Edge cases

- **Empty NL input** (user presses Ctrl+G then Enter with no text) → cancel, restore buffer
- **LLM returns empty** (unsure/unsafe) → show "Couldn't generate a command" briefly, restore buffer
- **Daemon unreachable** → show "shai: daemon not running, start with `shai start`", restore buffer
- **Timeout** → show "shai: timed out", restore buffer
- **Network failure** → 1 retry with 500ms delay. If both attempts fail, show "shai: couldn't reach API — check your connection", restore buffer
- **Circuit breaker open (offline)** → instant error: "shai: offline", restore buffer. No network call, no wait.
- **Dangerous command detected** → still place it in buffer but prepend a `⚠️` warning in `$POSTDISPLAY`: `"⚠️ This command modifies system files. Review carefully."`
