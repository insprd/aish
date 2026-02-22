# ghst.zsh — Main shell integration
# Loaded via: eval "$(ghst shell-init zsh)"
#
# Sets up precmd/preexec hooks, auto-reload, cheat sheet (Ctrl+/)

# ── Guard ────────────────────────────────────────────────────────────────────
if [[ -n "$__GHST_LOADED" ]]; then
    # Already loaded — skip re-init but don't return (would exit shell in eval)
    :
else
typeset -g __GHST_LOADED=1

# ── State variables ──────────────────────────────────────────────────────────
typeset -g __GHST_LAST_EXIT=0
typeset -g __GHST_LAST_CMD=""
typeset -g __GHST_CMD_COUNT=0

# ── Helpers ──────────────────────────────────────────────────────────────────

# Get recent history entries (one per line)
__ghst_get_history() {
    fc -l -50 -1 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//'
}

# Send a JSON request to the daemon and print the response
__ghst_request() {
    local json="$1"
    local timeout="${2:-10}"
    if command -v socat &>/dev/null; then
        echo "$json" | socat -T "$timeout" - UNIX-CONNECT:"$__GHST_SOCKET" 2>/dev/null
    else
        python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.settimeout($timeout)
    s.connect('$__GHST_SOCKET')
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
__ghst_preexec() {
    __GHST_LAST_CMD="$1"
}

# ── precmd hook — record exit status ─────────────────────────────────────────
__ghst_precmd() {
    __GHST_LAST_EXIT=$?

    # Auto-reload check (every 30 commands)
    (( __GHST_CMD_COUNT++ ))
    if (( __GHST_CMD_COUNT % 30 == 0 )) && [[ -n "$__GHST_SRC_DIR" ]]; then
        __ghst_check_reload
    fi
}

# ── Auto-reload ──────────────────────────────────────────────────────────────
__ghst_check_reload() {
    local pid_file
    # Find PID file
    if [[ -n "$XDG_RUNTIME_DIR" ]]; then
        pid_file="$XDG_RUNTIME_DIR/ghst.pid"
    else
        pid_file="/tmp/ghst-$(id -u).pid"
    fi

    [[ -f "$pid_file" ]] || return

    # Check if any .py file is newer than PID file
    local newer
    newer=$(find "$__GHST_SRC_DIR" -name '*.py' -newer "$pid_file" -print -quit 2>/dev/null)
    if [[ -n "$newer" ]]; then
        ghst stop &>/dev/null
        ghst start --quiet &>/dev/null
    fi
}

# ── Cheat sheet widget (Ctrl+/) ─────────────────────────────────────────────
__ghst_cheat_sheet() {
    POSTDISPLAY=$'\n'"$(cat <<'EOF'
  ┌─────────────────────────────────────────┐
  │  ghst shortcuts                         │
  │                                         │
  │  Tab / →     Accept autocomplete        │
  │  Shift+→     Accept one word            │
  │  Esc         Dismiss suggestion         │
  │  Ctrl+G      Natural language command   │
  │  Ctrl+R      Search history by intent   │
  │  Ctrl+Z      Undo generated command     │
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
zle -N __ghst_cheat_sheet

# ── Register hooks ───────────────────────────────────────────────────────────
autoload -Uz add-zsh-hook
add-zsh-hook preexec __ghst_preexec
add-zsh-hook precmd __ghst_precmd

# ── Keybindings ──────────────────────────────────────────────────────────────
bindkey '^_' __ghst_cheat_sheet  # Ctrl+/

fi  # end of __GHST_LOADED guard
