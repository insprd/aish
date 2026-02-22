# autocomplete.zsh — Ghost text autocomplete via ZLE
#
# Displays LLM suggestions as dimmed text after the cursor.
# Uses BUFFER + region_highlight (like zsh-autosuggestions).
# Accept with Tab/→, dismiss with Esc or any other key.

# ── State ────────────────────────────────────────────────────────────────────
typeset -g __AISH_SUGGESTION=""
typeset -g __AISH_BUFFER_LEN=0
typeset -g __AISH_REQUEST_ID=""
typeset -g __AISH_ASYNC_PID=""
typeset -g __AISH_RESULT_FILE="/tmp/aish-result-$$.json"

# ── Configuration ────────────────────────────────────────────────────────────
typeset -g __AISH_DELAY=${__AISH_DELAY:-200}
typeset -g __AISH_DELAY_SHORT=${__AISH_DELAY_SHORT:-100}
typeset -g __AISH_DELAY_THRESHOLD=${__AISH_DELAY_THRESHOLD:-8}
typeset -g __AISH_MIN_CHARS=${__AISH_MIN_CHARS:-3}
typeset -g __AISH_HIGHLIGHT="fg=8"

# ── Remove ghost text from buffer ────────────────────────────────────────────
__aish_clear_ghost() {
    if [[ -n "$__AISH_SUGGESTION" ]]; then
        BUFFER="${BUFFER[1,$__AISH_BUFFER_LEN]}"
        CURSOR=$__AISH_BUFFER_LEN
        __AISH_SUGGESTION=""
        region_highlight=("${(@)region_highlight:#*$__AISH_HIGHLIGHT*}")
        zle -R
    fi
}

# ── Append ghost text to buffer ──────────────────────────────────────────────
__aish_draw_ghost() {
    local suggestion="$1"
    if [[ -n "$suggestion" ]]; then
        # Clear existing ghost if any
        if [[ -n "$__AISH_SUGGESTION" ]]; then
            BUFFER="${BUFFER[1,$__AISH_BUFFER_LEN]}"
            region_highlight=("${(@)region_highlight:#*$__AISH_HIGHLIGHT*}")
        fi
        __AISH_SUGGESTION="$suggestion"
        __AISH_BUFFER_LEN=${#BUFFER}
        BUFFER="${BUFFER}${suggestion}"
        region_highlight+=("$__AISH_BUFFER_LEN ${#BUFFER} $__AISH_HIGHLIGHT")
        CURSOR=$__AISH_BUFFER_LEN
        zle -R
    fi
}

# ── Generate request ID ─────────────────────────────────────────────────────
__aish_gen_request_id() {
    __AISH_REQUEST_ID="req-$$-$RANDOM"
}

# ── Signal handler: receive async suggestion ─────────────────────────────────
TRAPUSR1() {
    if [[ -f "$__AISH_RESULT_FILE" ]]; then
        local response
        response=$(<"$__AISH_RESULT_FILE")
        rm -f "$__AISH_RESULT_FILE"

        [[ -z "$response" ]] && return

        # Extract request_id
        local resp_id=""
        if [[ "$response" == *'"request_id"'* ]]; then
            resp_id="${response#*\"request_id\": \"}"
            resp_id="${resp_id%%\"*}"
        fi

        [[ "$resp_id" != "$__AISH_REQUEST_ID" ]] && return

        # Extract suggestion
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
    fi
}

# ── Cancel pending request ───────────────────────────────────────────────────
__aish_cancel_pending() {
    if [[ -n "$__AISH_ASYNC_PID" ]] && kill -0 "$__AISH_ASYNC_PID" 2>/dev/null; then
        kill "$__AISH_ASYNC_PID" 2>/dev/null
    fi
    __AISH_ASYNC_PID=""
    rm -f "$__AISH_RESULT_FILE"
}

# ── Send autocomplete request ────────────────────────────────────────────────
__aish_send_autocomplete() {
    [[ -S "$__AISH_SOCKET" ]] || return

    __aish_cancel_pending
    __aish_gen_request_id

    local req_id="$__AISH_REQUEST_ID"
    local buf="$BUFFER"
    local cur="$CURSOR"
    local cwd="$PWD"
    local exit_st="$__AISH_LAST_EXIT"
    local sock="$__AISH_SOCKET"
    local result_file="$__AISH_RESULT_FILE"
    local shell_pid=$$

    local delay=$__AISH_DELAY
    if [[ ${#buf} -ge $__AISH_DELAY_THRESHOLD ]]; then
        delay=$__AISH_DELAY_SHORT
    fi

    # Background process: debounce → request → write result → signal parent
    {
        sleep $(( delay / 1000.0 ))
        python3 -c "
import socket, sys, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.settimeout(10)
    s.connect(sys.argv[6])
    req = {'type':'complete','request_id':sys.argv[3],'buffer':sys.argv[1],
           'cursor_pos':int(sys.argv[2]),'cwd':sys.argv[4],'shell':'zsh',
           'history':[],'exit_status':int(sys.argv[5])}
    s.sendall(json.dumps(req).encode() + b'\n')
    data = b''
    while True:
        chunk = s.recv(4096)
        if not chunk: break
        data += chunk
        if b'\n' in data: break
    with open(sys.argv[7], 'w') as f:
        f.write(data.decode().strip())
except: pass
finally: s.close()
" "$buf" "$cur" "$req_id" "$cwd" "$exit_st" "$sock" "$result_file" 2>/dev/null
        kill -USR1 "$shell_pid" 2>/dev/null
    } &!
    __AISH_ASYNC_PID=$!
}

# ── Custom self-insert widget ────────────────────────────────────────────────
__aish_self_insert() {
    if [[ -n "$__AISH_SUGGESTION" ]]; then
        local key="$KEYS"
        if [[ -n "$key" && "${__AISH_SUGGESTION[1]}" == "$key" ]]; then
            # Prefix reuse: typed char matches suggestion start
            BUFFER="${BUFFER[1,$__AISH_BUFFER_LEN]}"
            region_highlight=("${(@)region_highlight:#*$__AISH_HIGHLIGHT*}")
            zle .self-insert
            __AISH_BUFFER_LEN=${#BUFFER}
            __AISH_SUGGESTION="${__AISH_SUGGESTION:1}"
            if [[ -n "$__AISH_SUGGESTION" ]]; then
                BUFFER="${BUFFER}${__AISH_SUGGESTION}"
                region_highlight+=("$__AISH_BUFFER_LEN ${#BUFFER} $__AISH_HIGHLIGHT")
                CURSOR=$__AISH_BUFFER_LEN
            fi
            zle -R
            return
        fi
        __aish_clear_ghost
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
        CURSOR=${#BUFFER}
        __AISH_BUFFER_LEN=${#BUFFER}
        __AISH_SUGGESTION=""
        region_highlight=("${(@)region_highlight:#*$__AISH_HIGHLIGHT*}")
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
            CURSOR=${#BUFFER}
            __AISH_BUFFER_LEN=${#BUFFER}
            __AISH_SUGGESTION=""
            region_highlight=("${(@)region_highlight:#*$__AISH_HIGHLIGHT*}")
        else
            __AISH_BUFFER_LEN=$(( __AISH_BUFFER_LEN + ${#word} + 1 ))
            CURSOR=$__AISH_BUFFER_LEN
            __AISH_SUGGESTION="${__AISH_SUGGESTION#$word }"
            region_highlight=("${(@)region_highlight:#*$__AISH_HIGHLIGHT*}")
            region_highlight+=("$__AISH_BUFFER_LEN ${#BUFFER} $__AISH_HIGHLIGHT")
        fi
        zle -R
    else
        zle .forward-char
    fi
}
zle -N forward-char __aish_forward_char

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
    __aish_cancel_pending
    zle .accept-line
}
zle -N accept-line __aish_accept_line

# ── Keybindings ──────────────────────────────────────────────────────────────
bindkey '^I' __aish_accept_suggestion    # Tab
bindkey '\e[C' forward-char              # Right arrow
