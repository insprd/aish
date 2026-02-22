# autocomplete.zsh — Ghost text autocomplete via ZLE
#
# Displays LLM suggestions as dimmed text after the cursor.
# Accept with Tab/→, dismiss with Esc or any other key.

# ── State ────────────────────────────────────────────────────────────────────
typeset -g __AISH_SUGGESTION=""
typeset -g __AISH_REQUEST_ID=""
typeset -g __AISH_DEBOUNCE_FD=""
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

# ── Send autocomplete request ────────────────────────────────────────────────
__aish_send_request() {
    # Don't send if socket doesn't exist
    [[ -S "$__AISH_SOCKET" ]] || return

    __aish_gen_request_id

    local history_json
    history_json=$(python3 -c "
import json, sys
lines = sys.argv[1].strip().split('\n')
lines = [l for l in lines if l]
print(json.dumps(lines[-5:]))
" "$(__aish_get_history)" 2>/dev/null)
    [[ -z "$history_json" ]] && history_json='[]'

    local json_request
    if [[ -z "$BUFFER" && -n "$__AISH_CAPTURED_OUTPUT" && "$__AISH_PROACTIVE" == "1" ]]; then
        # Proactive suggestion (empty buffer with output)
        json_request=$(python3 -c "
import json, sys
output = sys.argv[1]
cmd = sys.argv[2]
req_id = sys.argv[3]
cwd = sys.argv[4]
history = json.loads(sys.argv[5])
exit_status = int(sys.argv[6])
print(json.dumps({'type':'complete','request_id':req_id,'buffer':'','cursor_pos':0,'cwd':cwd,'shell':'zsh','history':history,'exit_status':exit_status,'last_command':cmd,'last_output':output}))
" "$__AISH_CAPTURED_OUTPUT" "$__AISH_LAST_CMD" "$__AISH_REQUEST_ID" "$PWD" "$history_json" "$__AISH_LAST_EXIT" 2>/dev/null)
    else
        # Regular autocomplete
        json_request=$(python3 -c "
import json, sys
buf = sys.argv[1]
cursor = int(sys.argv[2])
req_id = sys.argv[3]
cwd = sys.argv[4]
history = json.loads(sys.argv[5])
exit_status = int(sys.argv[6])
print(json.dumps({'type':'complete','request_id':req_id,'buffer':buf,'cursor_pos':cursor,'cwd':cwd,'shell':'zsh','history':history,'exit_status':exit_status}))
" "$BUFFER" "$CURSOR" "$__AISH_REQUEST_ID" "$PWD" "$history_json" "$__AISH_LAST_EXIT" 2>/dev/null)
    fi

    __aish_request_async "$json_request" __aish_autocomplete_callback
}

# ── Debounce timer callback ─────────────────────────────────────────────────
__aish_debounce_fire() {
    local fd=$1
    zle -F $fd  # Unregister
    exec {fd}<&-

    # Check minimum chars
    if [[ ${#BUFFER} -lt $__AISH_MIN_CHARS && -n "$BUFFER" ]]; then
        return
    fi

    __aish_send_request
}

# ── Start debounce timer ─────────────────────────────────────────────────────
__aish_debounce() {
    # Cancel previous timer
    if [[ -n "$__AISH_DEBOUNCE_FD" ]]; then
        zle -F $__AISH_DEBOUNCE_FD 2>/dev/null
        exec {__AISH_DEBOUNCE_FD}<&- 2>/dev/null
        __AISH_DEBOUNCE_FD=""
    fi

    # Adaptive delay
    local delay=$__AISH_DELAY
    if [[ ${#BUFFER} -ge $__AISH_DELAY_THRESHOLD ]]; then
        delay=$__AISH_DELAY_SHORT
    fi

    # Create a timer using a sleep subprocess with fd
    local delay_sec=$(printf '%.3f' "$(echo "scale=3; $delay/1000" | bc)")
    exec {__AISH_DEBOUNCE_FD}< <(sleep "$delay_sec" && echo "fire")
    zle -F $__AISH_DEBOUNCE_FD __aish_debounce_fire
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

    # Start debounce for new request
    __aish_debounce
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
    # Restart debounce if buffer still has content
    if [[ ${#BUFFER} -ge $__AISH_MIN_CHARS ]]; then
        __aish_debounce
    fi
}
zle -N backward-delete-char __aish_backward_delete_char

# ── Handle Enter (accept line) ───────────────────────────────────────────────
__aish_accept_line() {
    __aish_clear_ghost
    zle .accept-line
}
zle -N accept-line __aish_accept_line

# ── Proactive suggestions on empty prompt ────────────────────────────────────
__aish_proactive_check() {
    # Called from precmd via zle-line-init
    if [[ -z "$BUFFER" && -n "$__AISH_CAPTURED_OUTPUT" && "$__AISH_PROACTIVE" == "1" ]]; then
        # Check if error correction should take priority
        if [[ "$__AISH_LAST_EXIT" != "0" && "$__AISH_ERROR_CORRECTION" == "1" ]]; then
            __aish_send_error_correction
            return
        fi

        # Run heuristic pre-filter
        if __aish_output_is_actionable "$__AISH_CAPTURED_OUTPUT" "$__AISH_LAST_EXIT"; then
            __aish_send_request
        fi
    elif [[ -z "$BUFFER" && "$__AISH_LAST_EXIT" != "0" && "$__AISH_ERROR_CORRECTION" == "1" ]]; then
        __aish_send_error_correction
    fi

    # Clear captured output after use
    __AISH_CAPTURED_OUTPUT=""
}

# ── Error correction ─────────────────────────────────────────────────────────
__aish_error_correction_callback() {
    local fd=$1
    local response

    zle -F $fd
    read -r response <&$fd
    exec {fd}<&-

    [[ -z "$response" ]] && return

    local suggestion
    suggestion=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('suggestion', ''))
except: pass
" <<< "$response")

    if [[ -n "$suggestion" ]]; then
        __aish_draw_ghost "$suggestion"
    fi
}

__aish_send_error_correction() {
    [[ -S "$__AISH_SOCKET" ]] || return

    local json_request
    json_request=$(python3 -c "
import json, sys
print(json.dumps({'type':'error_correct','failed_command':sys.argv[1],'exit_status':int(sys.argv[2]),'stderr':sys.argv[3],'cwd':sys.argv[4],'shell':'zsh'}))
" "$__AISH_LAST_CMD" "$__AISH_LAST_EXIT" "${__AISH_CAPTURED_OUTPUT:-}" "$PWD" 2>/dev/null)

    __aish_request_async "$json_request" __aish_error_correction_callback
}

# ── zle-line-init: trigger proactive check when new prompt appears ───────────
__aish_line_init() {
    __aish_proactive_check
}
zle -N zle-line-init __aish_line_init

# ── Keybindings ──────────────────────────────────────────────────────────────
bindkey '^I' __aish_accept_suggestion    # Tab
bindkey '\e[C' forward-char              # Right arrow (uses our override)
bindkey '\e' __aish_dismiss              # Esc — only when ghost text visible
