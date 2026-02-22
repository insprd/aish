# autocomplete.zsh — Ghost text autocomplete via ZLE
#
# Displays LLM suggestions as dimmed text after the cursor.
# Uses BUFFER + region_highlight (like zsh-autosuggestions).
# Accept with Tab/→, dismiss with Esc or any other key.

# ── State ────────────────────────────────────────────────────────────────────
typeset -g __AISH_SUGGESTION=""
typeset -g __AISH_BUFFER_LEN=0        # real buffer length (before ghost text)
typeset -g __AISH_REQUEST_ID=""
typeset -g __AISH_PENDING_FD=""

# ── Configuration ────────────────────────────────────────────────────────────
typeset -g __AISH_DELAY=${__AISH_DELAY:-200}
typeset -g __AISH_DELAY_SHORT=${__AISH_DELAY_SHORT:-100}
typeset -g __AISH_DELAY_THRESHOLD=${__AISH_DELAY_THRESHOLD:-8}
typeset -g __AISH_MIN_CHARS=${__AISH_MIN_CHARS:-3}
typeset -g __AISH_HIGHLIGHT="fg=8"

# ── Remove ghost text from buffer ────────────────────────────────────────────
__aish_clear_ghost() {
    if [[ -n "$__AISH_SUGGESTION" ]]; then
        # Remove the appended ghost text from BUFFER
        BUFFER="${BUFFER[1,$__AISH_BUFFER_LEN]}"
        CURSOR=$__AISH_BUFFER_LEN
        __AISH_SUGGESTION=""
        region_highlight=("${(@)region_highlight:#*fg=8*}")
        zle -R
    fi
}

# ── Append ghost text to buffer ──────────────────────────────────────────────
__aish_draw_ghost() {
    local suggestion="$1"
    if [[ -n "$suggestion" ]]; then
        # Remove any existing ghost text first
        if [[ -n "$__AISH_SUGGESTION" ]]; then
            BUFFER="${BUFFER[1,$__AISH_BUFFER_LEN]}"
            region_highlight=("${(@)region_highlight:#*fg=8*}")
        fi
        __AISH_SUGGESTION="$suggestion"
        __AISH_BUFFER_LEN=${#BUFFER}
        # Append suggestion to buffer
        BUFFER="${BUFFER}${suggestion}"
        # Highlight the ghost portion as dim
        local start=$__AISH_BUFFER_LEN
        local end=${#BUFFER}
        region_highlight+=("$start $end $__AISH_HIGHLIGHT")
        # Keep cursor at the real end
        CURSOR=$__AISH_BUFFER_LEN
        zle -R
    fi
}

# ── Generate request ID ─────────────────────────────────────────────────────
__aish_gen_request_id() {
    __AISH_REQUEST_ID="req-$$-$RANDOM"
}

# ── Callback for async response ─────────────────────────────────────────────
__aish_autocomplete_callback() {
    local fd=$1
    local response

    zle -F $fd
    read -r response <&$fd
    exec {fd}<&-

    if [[ -z "$response" ]]; then
        return
    fi

    # Extract request_id (pure shell)
    local resp_id=""
    if [[ "$response" == *'"request_id"'* ]]; then
        resp_id="${response#*\"request_id\": \"}"
        resp_id="${resp_id%%\"*}"
    fi

    if [[ "$resp_id" != "$__AISH_REQUEST_ID" ]]; then
        return
    fi

    # Extract suggestion (pure shell)
    local suggestion=""
    if [[ "$response" == *'"suggestion": "'* ]]; then
        suggestion="${response#*\"suggestion\": \"}"
        suggestion="${suggestion%%\"*}"
        suggestion="${suggestion//\\n/$'\n'}"
        suggestion="${suggestion//\\\\/\\}"
    fi

    if [[ -n "$suggestion" ]]; then
        __aish_draw_ghost "$suggestion"
    fi
}

# ── Send autocomplete request ────────────────────────────────────────────────
__aish_send_autocomplete() {
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

    local delay=$__AISH_DELAY
    if [[ ${#buf} -ge $__AISH_DELAY_THRESHOLD ]]; then
        delay=$__AISH_DELAY_SHORT
    fi

    exec {__AISH_PENDING_FD}< <(
        sleep $(( delay / 1000.0 ))
        python3 -c "
import socket, sys, json
buf, cursor, req_id, cwd, exit_st = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5])
sock_path = sys.argv[6]
req = {'type':'complete','request_id':req_id,'buffer':buf,'cursor_pos':cursor,'cwd':cwd,'shell':'zsh','history':[],'exit_status':exit_st}
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
" "$buf" "$cur" "$req_id" "$cwd" "$exit_st" "$__AISH_SOCKET" 2>/dev/null
    )
    zle -F $__AISH_PENDING_FD __aish_autocomplete_callback
}

# ── Custom self-insert widget ────────────────────────────────────────────────
__aish_self_insert() {
    # Clear ghost text before inserting (so .self-insert works on clean buffer)
    if [[ -n "$__AISH_SUGGESTION" ]]; then
        # Check prefix reuse: does the new char match the start of suggestion?
        local key="$KEYS"
        if [[ -n "$key" && "${__AISH_SUGGESTION[1]}" == "$key" ]]; then
            # Consume one char from suggestion
            __AISH_SUGGESTION="${__AISH_SUGGESTION:1}"
            # Remove ghost, insert char normally, redraw ghost
            BUFFER="${BUFFER[1,$__AISH_BUFFER_LEN]}"
            region_highlight=("${(@)region_highlight:#*fg=8*}")
            zle .self-insert
            __AISH_BUFFER_LEN=${#BUFFER}
            if [[ -n "$__AISH_SUGGESTION" ]]; then
                BUFFER="${BUFFER}${__AISH_SUGGESTION}"
                local start=$__AISH_BUFFER_LEN
                local end=${#BUFFER}
                region_highlight+=("$start $end $__AISH_HIGHLIGHT")
                CURSOR=$__AISH_BUFFER_LEN
            fi
            zle -R
            return
        fi
        # No prefix match — clear ghost
        BUFFER="${BUFFER[1,$__AISH_BUFFER_LEN]}"
        __AISH_SUGGESTION=""
        region_highlight=("${(@)region_highlight:#*fg=8*}")
    fi

    zle .self-insert
    __AISH_BUFFER_LEN=${#BUFFER}

    if [[ ${#BUFFER} -lt $__AISH_MIN_CHARS ]]; then
        return
    fi
    __aish_send_autocomplete
}
zle -N self-insert __aish_self_insert

# ── Accept full suggestion (Tab) ─────────────────────────────────────────────
__aish_accept_suggestion() {
    if [[ -n "$__AISH_SUGGESTION" ]]; then
        # Ghost text is already in BUFFER — just move cursor to end and clear highlight
        CURSOR=${#BUFFER}
        __AISH_BUFFER_LEN=${#BUFFER}
        __AISH_SUGGESTION=""
        region_highlight=("${(@)region_highlight:#*fg=8*}")
        zle -R
    else
        zle expand-or-complete
    fi
}
zle -N __aish_accept_suggestion

# ── Accept one word (→ at end of line) ───────────────────────────────────────
__aish_forward_char() {
    if [[ -n "$__AISH_SUGGESTION" && $CURSOR -eq $__AISH_BUFFER_LEN ]]; then
        local word="${__AISH_SUGGESTION%% *}"
        if [[ "$word" == "$__AISH_SUGGESTION" ]]; then
            # Accept all
            CURSOR=${#BUFFER}
            __AISH_BUFFER_LEN=${#BUFFER}
            __AISH_SUGGESTION=""
            region_highlight=("${(@)region_highlight:#*fg=8*}")
        else
            # Accept one word
            __AISH_BUFFER_LEN=$(( __AISH_BUFFER_LEN + ${#word} + 1 ))
            CURSOR=$__AISH_BUFFER_LEN
            __AISH_SUGGESTION="${__AISH_SUGGESTION#$word }"
            # Update highlight
            region_highlight=("${(@)region_highlight:#*fg=8*}")
            region_highlight+=("$__AISH_BUFFER_LEN ${#BUFFER} $__AISH_HIGHLIGHT")
        fi
        zle -R
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
    __AISH_BUFFER_LEN=${#BUFFER}
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

# ── Keybindings ──────────────────────────────────────────────────────────────
bindkey '^I' __aish_accept_suggestion    # Tab
bindkey '\e[C' forward-char              # Right arrow
bindkey '\e' __aish_dismiss              # Esc
