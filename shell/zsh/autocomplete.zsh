# autocomplete.zsh — Ghost text autocomplete via ZLE
#
# Displays LLM suggestions as dimmed text after the cursor.
# Accept with Tab/→, dismiss with Esc or any other key.

# ── State ────────────────────────────────────────────────────────────────────
typeset -g __AISH_SUGGESTION=""
typeset -g __AISH_REQUEST_ID=""
typeset -g __AISH_PENDING_FD=""
typeset -g __AISH_PROACTIVE_PENDING=0

# ── Configuration ────────────────────────────────────────────────────────────
typeset -g __AISH_DELAY=${__AISH_DELAY:-200}
typeset -g __AISH_DELAY_SHORT=${__AISH_DELAY_SHORT:-100}
typeset -g __AISH_DELAY_THRESHOLD=${__AISH_DELAY_THRESHOLD:-8}
typeset -g __AISH_MIN_CHARS=${__AISH_MIN_CHARS:-3}

# ── Clear ghost text ─────────────────────────────────────────────────────────
__aish_clear_ghost() {
    if [[ -n "$__AISH_SUGGESTION" ]]; then
        __AISH_SUGGESTION=""
        POSTDISPLAY=""
        zle -R
    fi
}

# ── Draw ghost text ──────────────────────────────────────────────────────────
__aish_draw_ghost() {
    local suggestion="$1"
    if [[ -n "$suggestion" ]]; then
        __AISH_SUGGESTION="$suggestion"
        # Show as dimmed text
        POSTDISPLAY=$'\e[90m'"${suggestion}"$'\e[0m'
        zle -R
    fi
}

# ── Generate request ID ─────────────────────────────────────────────────────
__aish_gen_request_id() {
    __AISH_REQUEST_ID="req-$$-$RANDOM"
}

# ── Get history for context ─────────────────────────────────────────────────
__aish_get_history() {
    fc -l -5 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' || true
}

# ── Callback for async response ─────────────────────────────────────────────
__aish_autocomplete_callback() {
    local fd=$1
    local response

    # Read the response
    zle -F $fd  # Unregister handler
    read -r response <&$fd
    exec {fd}<&-  # Close fd

    # Parse response
    if [[ -z "$response" ]]; then
        return
    fi

    # Extract suggestion and request_id using python (reliable JSON parsing)
    local result
    result=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    rid = d.get('request_id', '')
    sug = d.get('suggestion', '')
    warn = d.get('warning', '')
    print(f'{rid}\t{sug}\t{warn}')
except: pass
" <<< "$response")

    local resp_id="${result%%	*}"
    local rest="${result#*	}"
    local suggestion="${rest%%	*}"
    local warning="${rest##*	}"

    # Check if this response is still current
    if [[ "$resp_id" != "$__AISH_REQUEST_ID" ]]; then
        return  # Stale response
    fi

    # Draw ghost text
    if [[ -n "$suggestion" ]]; then
        __aish_draw_ghost "$suggestion"

        # Show warning in POSTDISPLAY if present
        if [[ -n "$warning" ]]; then
            POSTDISPLAY=$'\e[90m'"${suggestion}"$'\e[0m\n\e[33m'"${warning}"$'\e[0m'
            zle -R
        fi

        # First-use hint
        if [[ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/aish/.onboarded" ]]; then
            POSTDISPLAY=$'\e[90m'"${suggestion}"$'\e[0m\n\e[2maish: ghost text suggestion (Tab to accept, → to accept word, Esc to dismiss)\e[0m'
            zle -R
            mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/aish"
            touch "${XDG_CONFIG_HOME:-$HOME/.config}/aish/.onboarded"
        fi
    fi
}

# ── Send autocomplete request (async with built-in delay) ────────────────────
__aish_send_autocomplete() {
    # Don't send if socket doesn't exist
    [[ -S "$__AISH_SOCKET" ]] || return

    # Cancel any pending request
    if [[ -n "$__AISH_PENDING_FD" ]]; then
        zle -F $__AISH_PENDING_FD 2>/dev/null
        exec {__AISH_PENDING_FD}<&- 2>/dev/null
        __AISH_PENDING_FD=""
    fi

    __aish_gen_request_id
    local req_id="$__AISH_REQUEST_ID"
    local buf="$BUFFER"
    local cur="$CURSOR"
    local cwd="$PWD"
    local exit_st="$__AISH_LAST_EXIT"

    # Adaptive delay (ms)
    local delay=$__AISH_DELAY
    if [[ ${#buf} -ge $__AISH_DELAY_THRESHOLD ]]; then
        delay=$__AISH_DELAY_SHORT
    fi

    # Single background process: delay → build JSON → send to daemon → return response
    exec {__AISH_PENDING_FD}< <(
        # Debounce delay
        sleep $(( delay / 1000.0 ))
        # Build JSON, send to daemon, return response
        python3 -c "
import socket, sys, json
buf, cursor, req_id, cwd, exit_st = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5])
last_cmd = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else None
last_output = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else None
sock_path = sys.argv[8]
history = []
try:
    import subprocess
    h = subprocess.run(['fc', '-l', '-5'], capture_output=True, text=True, shell=False)
except: pass
req = {'type':'complete','request_id':req_id,'buffer':buf,'cursor_pos':cursor,'cwd':cwd,'shell':'zsh','history':history,'exit_status':exit_st}
if last_cmd: req['last_command'] = last_cmd
if last_output: req['last_output'] = last_output
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.settimeout(10)
    s.connect(sock_path)
    s.sendall(json.dumps(req).encode() + b'\n')
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
" "$buf" "$cur" "$req_id" "$cwd" "$exit_st" \
  "${__AISH_LAST_CMD:-}" "${__AISH_CAPTURED_OUTPUT:-}" "$__AISH_SOCKET" 2>/dev/null
    )
    zle -F $__AISH_PENDING_FD __aish_autocomplete_callback
}

# ── Prefix reuse ─────────────────────────────────────────────────────────────
__aish_try_prefix_reuse() {
    # If we have an existing suggestion and the user typed a char that matches,
    # trim the suggestion instead of making a new API call
    if [[ -n "$__AISH_SUGGESTION" && -n "$BUFFER" ]]; then
        local prev_buffer="${BUFFER%?}"  # Buffer before this keystroke
        local new_char="${BUFFER: -1}"
        local expected="${__AISH_SUGGESTION:0:1}"

        if [[ "$new_char" == "$expected" ]]; then
            __AISH_SUGGESTION="${__AISH_SUGGESTION:1}"
            if [[ -n "$__AISH_SUGGESTION" ]]; then
                __aish_draw_ghost "$__AISH_SUGGESTION"
            else
                __aish_clear_ghost
            fi
            return 0  # Reused
        fi
    fi
    return 1  # No reuse possible
}

# ── Custom self-insert widget ────────────────────────────────────────────────
__aish_self_insert() {
    zle .self-insert

    # Try prefix reuse first
    if __aish_try_prefix_reuse; then
        return
    fi

    # Clear existing ghost text
    __aish_clear_ghost

    # Check minimum chars
    if [[ ${#BUFFER} -lt $__AISH_MIN_CHARS ]]; then
        return
    fi

    # Send async request (includes debounce delay)
    __aish_send_autocomplete
}
zle -N self-insert __aish_self_insert

# ── Accept full suggestion (Tab) ─────────────────────────────────────────────
__aish_accept_suggestion() {
    if [[ -n "$__AISH_SUGGESTION" ]]; then
        BUFFER="${BUFFER}${__AISH_SUGGESTION}"
        CURSOR=${#BUFFER}
        __aish_clear_ghost
    else
        # Fall through to normal Tab completion
        zle expand-or-complete
    fi
}
zle -N __aish_accept_suggestion

# ── Accept one word (→ at end of line) ───────────────────────────────────────
__aish_forward_char() {
    if [[ -n "$__AISH_SUGGESTION" && $CURSOR -eq ${#BUFFER} ]]; then
        # Accept first word from suggestion
        local word="${__AISH_SUGGESTION%% *}"
        if [[ "$word" == "$__AISH_SUGGESTION" ]]; then
            # No space — accept all
            BUFFER="${BUFFER}${__AISH_SUGGESTION}"
            CURSOR=${#BUFFER}
            __aish_clear_ghost
        else
            BUFFER="${BUFFER}${word} "
            CURSOR=${#BUFFER}
            __AISH_SUGGESTION="${__AISH_SUGGESTION#$word }"
            __aish_draw_ghost "$__AISH_SUGGESTION"
        fi
    else
        zle .forward-char
    fi
}
zle -N forward-char __aish_forward_char

# ── Dismiss suggestion (Esc) ─────────────────────────────────────────────────
__aish_dismiss() {
    __aish_clear_ghost
}

# ── Handle backspace ─────────────────────────────────────────────────────────
__aish_backward_delete_char() {
    __aish_clear_ghost
    zle .backward-delete-char
    # Restart request if buffer still has content
    if [[ ${#BUFFER} -ge $__AISH_MIN_CHARS ]]; then
        __aish_send_autocomplete
    fi
}
zle -N backward-delete-char __aish_backward_delete_char

# ── Handle Enter (accept line) ───────────────────────────────────────────────
__aish_accept_line() {
    __aish_clear_ghost
    zle .accept-line
}
zle -N accept-line __aish_accept_line

# ── Debug: synchronous test (Ctrl+T) ────────────────────────────────────────
__aish_debug_test() {
    [[ -S "$__AISH_SOCKET" ]] || { zle -M "aish debug: socket not found at $__AISH_SOCKET"; return; }

    local json_request
    json_request=$(python3 -c "
import json, sys
print(json.dumps({'type':'complete','request_id':'debug','buffer':sys.argv[1],'cursor_pos':int(sys.argv[2]),'cwd':sys.argv[3],'shell':'zsh','history':[],'exit_status':0}))
" "$BUFFER" "$CURSOR" "$PWD" 2>&1)

    if [[ -z "$json_request" ]]; then
        zle -M "aish debug: failed to build JSON"
        return
    fi

    zle -M "aish debug: sending request..."
    local response
    response=$(__aish_request "$json_request")
    zle -M "aish debug: response=$response"

    if [[ -n "$response" ]]; then
        local suggestion
        suggestion=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d.get('suggestion', ''))
" "$response" 2>/dev/null)
        if [[ -n "$suggestion" ]]; then
            __aish_draw_ghost "$suggestion"
        fi
    fi
}
zle -N __aish_debug_test
bindkey '^T' __aish_debug_test

# ── Keybindings ──────────────────────────────────────────────────────────────
bindkey '^I' __aish_accept_suggestion    # Tab
bindkey '\e[C' forward-char              # Right arrow (uses our override)
bindkey '\e' __aish_dismiss              # Esc — only when ghost text visible
