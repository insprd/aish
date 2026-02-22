# aish.zsh — Main shell integration
# Loaded via: eval "$(aish shell-init zsh)"
#
# Sets up precmd/preexec hooks, auto-reload, cheat sheet (Ctrl+/)

# ── Guard ────────────────────────────────────────────────────────────────────
if [[ -n "$__AISH_LOADED" ]]; then
    # Already loaded — skip re-init but don't return (would exit shell in eval)
    :
else
typeset -g __AISH_LOADED=1

# ── State variables ──────────────────────────────────────────────────────────
typeset -g __AISH_LAST_EXIT=0
typeset -g __AISH_LAST_CMD=""
typeset -g __AISH_CMD_COUNT=0

# ── Helpers ──────────────────────────────────────────────────────────────────

# Get recent history entries (one per line)
__aish_get_history() {
    fc -l -50 -1 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//'
}

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

# ── preexec hook — record last command ────────────────────────────────────────
__aish_preexec() {
    __AISH_LAST_CMD="$1"
}

# ── precmd hook — record exit status ─────────────────────────────────────────
__aish_precmd() {
    __AISH_LAST_EXIT=$?

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

# ── Keybindings ──────────────────────────────────────────────────────────────
bindkey '^_' __aish_cheat_sheet  # Ctrl+/

fi  # end of __AISH_LOADED guard
