# aish.zsh — Main shell integration
# Loaded via: eval "$(aish shell-init zsh)"
#
# Sets up precmd/preexec hooks for:
# - Output capture (for proactive suggestions)
# - Error correction
# - Auto-reload of daemon on source changes
# - Cheat sheet widget (Ctrl+/)

# ── Guard ────────────────────────────────────────────────────────────────────
[[ -n "$__AISH_LOADED" ]] && return
typeset -g __AISH_LOADED=1

# ── State variables ──────────────────────────────────────────────────────────
typeset -g __AISH_LAST_EXIT=0
typeset -g __AISH_LAST_CMD=""
typeset -g __AISH_CAPTURED_OUTPUT=""
typeset -g __AISH_OUTPUT_FILE=""
typeset -g __AISH_TEE_OUT_PID=""
typeset -g __AISH_TEE_ERR_PID=""
typeset -g __AISH_STDOUT_BAK=""
typeset -g __AISH_STDERR_BAK=""
typeset -g __AISH_CMD_COUNT=0
typeset -g __AISH_CAPTURE_ACTIVE=0

# ── Config (read from exported vars or defaults) ─────────────────────────────
typeset -g __AISH_PROACTIVE=${__AISH_PROACTIVE:-1}
typeset -g __AISH_ERROR_CORRECTION=${__AISH_ERROR_CORRECTION:-1}

# Interactive command blocklist for output capture
typeset -ga __AISH_BLOCKLIST=(
    vim nvim vi nano emacs pico
    less more most bat
    top htop btop glances
    tmux screen
    ssh mosh
    python ipython node irb ghci
    fzf sk
    man info
    watch
)

# ── Helpers ──────────────────────────────────────────────────────────────────

# Send a JSON request to the daemon and print the response
__aish_request() {
    local json="$1"
    # Use socat if available, fall back to zsh /dev/tcp or python
    if command -v socat &>/dev/null; then
        echo "$json" | socat - UNIX-CONNECT:"$__AISH_SOCKET" 2>/dev/null
    else
        python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.settimeout(5)
    s.connect('$__AISH_SOCKET')
    s.sendall(sys.stdin.buffer.read())
    data = b''
    while True:
        chunk = s.recv(4096)
        if not chunk: break
        data += chunk
        if b'\n' in data: break
    sys.stdout.buffer.write(data)
except: pass
finally: s.close()
" <<< "$json"
    fi
}

# Send a request asynchronously and set up fd watcher for the response
# Usage: __aish_request_async "$json" callback_function
__aish_request_async() {
    local json="$1"
    local callback="$2"

    local fd
    if command -v socat &>/dev/null; then
        exec {fd}< <(echo "$json" | socat - UNIX-CONNECT:"$__AISH_SOCKET" 2>/dev/null)
    else
        exec {fd}< <(python3 -c "
import socket, sys, json as J
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.settimeout(10)
    s.connect('$__AISH_SOCKET')
    payload = sys.argv[1].encode() + b'\n'
    s.sendall(payload)
    data = b''
    while True:
        chunk = s.recv(4096)
        if not chunk: break
        data += chunk
        if b'\n' in data: break
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
except: pass
finally: s.close()
" "$json" 2>/dev/null)
    fi

    zle -F $fd "$callback"
}

# Check if a command is in the blocklist
__aish_is_blocked() {
    local cmd_word="${1%% *}"
    local blocked
    for blocked in "${__AISH_BLOCKLIST[@]}"; do
        [[ "$cmd_word" == "$blocked" ]] && return 0
    done
    return 1
}

# Strip ANSI escape codes from text
__aish_strip_ansi() {
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g'
}

# Heuristic pre-filter: check if output is worth sending to the LLM
__aish_output_is_actionable() {
    local output="$1"
    local exit_status="$2"

    # Non-zero exit always qualifies
    [[ "$exit_status" != "0" ]] && return 0

    # Check for actionable patterns
    echo "$output" | grep -qiE \
        '(^|\s)(run |try |use |resume |execute |install |fix |resolve |update |upgrade )' \
        && return 0
    echo "$output" | grep -qE '`[a-zA-Z]' && return 0
    echo "$output" | grep -qE '^\s*\$\s+[a-zA-Z]' && return 0
    echo "$output" | grep -qE '(--set-upstream|audit fix|--resume=)' && return 0

    return 1
}

# ── preexec hook — capture output ────────────────────────────────────────────
__aish_preexec() {
    __AISH_LAST_CMD="$1"
    __AISH_CAPTURE_ACTIVE=0

    # Skip capture for blocked commands
    __aish_is_blocked "$1" && return

    # Skip if proactive suggestions are disabled
    [[ "$__AISH_PROACTIVE" != "1" ]] && return

    # Create temp file for output capture
    __AISH_OUTPUT_FILE=$(mktemp /tmp/aish-out-$$.XXXXXX)

    # Save original file descriptors
    exec {__AISH_STDOUT_BAK}>&1 {__AISH_STDERR_BAK}>&2

    # Create FIFOs
    local fifo_out=$(mktemp -u /tmp/aish-fo-$$.XXXXXX)
    local fifo_err=$(mktemp -u /tmp/aish-fe-$$.XXXXXX)
    mkfifo "$fifo_out" "$fifo_err"

    # Start tee processes (disowned to suppress job notifications)
    tee -a "$__AISH_OUTPUT_FILE" < "$fifo_out" >&$__AISH_STDOUT_BAK &!
    __AISH_TEE_OUT_PID=$!
    tee -a "$__AISH_OUTPUT_FILE" < "$fifo_err" >&$__AISH_STDERR_BAK &!
    __AISH_TEE_ERR_PID=$!

    # Redirect stdout/stderr to FIFOs
    exec > "$fifo_out" 2> "$fifo_err"

    # Unlink FIFOs (open fds keep them alive)
    rm -f "$fifo_out" "$fifo_err"

    __AISH_CAPTURE_ACTIVE=1
}

# ── precmd hook — process captured output, trigger suggestions ───────────────
__aish_precmd() {
    __AISH_LAST_EXIT=$?

    # Restore file descriptors if capture was active
    if [[ "$__AISH_CAPTURE_ACTIVE" == "1" ]]; then
        exec 1>&$__AISH_STDOUT_BAK 2>&$__AISH_STDERR_BAK
        exec {__AISH_STDOUT_BAK}>&- {__AISH_STDERR_BAK}>&-

        # Kill tee processes (disowned, so no wait needed)
        for _pid in $__AISH_TEE_OUT_PID $__AISH_TEE_ERR_PID; do
            if [[ -n "$_pid" ]] && kill -0 "$_pid" 2>/dev/null; then
                kill "$_pid" 2>/dev/null
            fi
        done

        # Read captured output
        if [[ -f "$__AISH_OUTPUT_FILE" ]]; then
            __AISH_CAPTURED_OUTPUT=$(tail -50 "$__AISH_OUTPUT_FILE" | __aish_strip_ansi)
            rm -f "$__AISH_OUTPUT_FILE"
        fi

        __AISH_CAPTURE_ACTIVE=0
        __AISH_TEE_OUT_PID=""
        __AISH_TEE_ERR_PID=""
    fi

    # Auto-reload check (every 30 commands)
    (( __AISH_CMD_COUNT++ ))
    if (( __AISH_CMD_COUNT % 30 == 0 )) && [[ -n "$__AISH_SRC_DIR" ]]; then
        __aish_check_reload
    fi
}

# ── Auto-reload ──────────────────────────────────────────────────────────────
__aish_check_reload() {
    local pid_file
    # Find PID file
    if [[ -n "$XDG_RUNTIME_DIR" ]]; then
        pid_file="$XDG_RUNTIME_DIR/aish.pid"
    else
        pid_file="/tmp/aish-$(id -u).pid"
    fi

    [[ -f "$pid_file" ]] || return

    # Check if any .py file is newer than PID file
    local newer
    newer=$(find "$__AISH_SRC_DIR" -name '*.py' -newer "$pid_file" -print -quit 2>/dev/null)
    if [[ -n "$newer" ]]; then
        aish stop &>/dev/null
        aish start --quiet &>/dev/null
    fi
}

# ── Cleanup on shell exit ────────────────────────────────────────────────────
__aish_zshexit() {
    # Kill any remaining tee processes
    for _pid in $__AISH_TEE_OUT_PID $__AISH_TEE_ERR_PID; do
        if [[ -n "$_pid" ]] && kill -0 "$_pid" 2>/dev/null; then
            kill "$_pid" 2>/dev/null
        fi
    done

    # Clean up temp files
    rm -f /tmp/aish-out-$$.* /tmp/aish-fo-$$.* /tmp/aish-fe-$$.*
}

# ── Cheat sheet widget (Ctrl+/) ─────────────────────────────────────────────
__aish_cheat_sheet() {
    POSTDISPLAY=$'\n'"$(cat <<'EOF'
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
EOF
)"
    zle -R

    # Read one key, then clear
    local key
    read -k 1 key
    POSTDISPLAY=""
    zle -R

    # If the key wasn't a control key, feed it back
    if [[ "$key" != $'\e' && "$key" != $'\n' && "$key" != $'\r' ]]; then
        zle -U "$key"
    fi
}
zle -N __aish_cheat_sheet

# ── Register hooks ───────────────────────────────────────────────────────────
autoload -Uz add-zsh-hook
add-zsh-hook preexec __aish_preexec
add-zsh-hook precmd __aish_precmd
add-zsh-hook zshexit __aish_zshexit

# ── Keybindings ──────────────────────────────────────────────────────────────
bindkey '^_' __aish_cheat_sheet  # Ctrl+/

# Clean up orphaned temp files from previous sessions
rm -f /tmp/aish-out-*.XXXXXX 2>/dev/null
