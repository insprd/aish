# autocomplete.zsh — ZLE ghost text widget
# Inline suggestions rendered via direct terminal escape codes

# ── State ────────────────────────────────────────────────────────────────────
typeset -g __SHAI_SUGGESTION=""
typeset -g __SHAI_TIMER_FD=""
typeset -g __SHAI_LAST_BUFFER=""
typeset -g __SHAI_PENDING_BUFFER=""
typeset -gi __SHAI_PENDING_CURSOR=0
typeset -gi __SHAI_GHOST_VISIBLE=0
typeset -g __SHAI_RESPONSE_FD=""

# ── Configuration ────────────────────────────────────────────────────────────
typeset -gi __SHAI_DELAY=${__SHAI_DELAY:-200}
typeset -gi __SHAI_DELAY_SHORT=${__SHAI_DELAY_SHORT:-100}
typeset -gi __SHAI_DELAY_THRESHOLD=${__SHAI_DELAY_THRESHOLD:-8}
typeset -gi __SHAI_MIN_CHARS=${__SHAI_MIN_CHARS:-3}

# ── Erase ghost text from terminal ───────────────────────────────────────────
__shai_erase_ghost() {
    if (( __SHAI_GHOST_VISIBLE )); then
        echo -n $'\e[0K' > /dev/tty
        __SHAI_GHOST_VISIBLE=0
    fi
}

# ── Draw ghost text at cursor position ───────────────────────────────────────
__shai_draw_ghost() {
    if [[ -n "$__SHAI_SUGGESTION" ]]; then
        local len=${#__SHAI_SUGGESTION}
        # Print gray text, then move cursor back
        echo -n $'\e[90m'"${__SHAI_SUGGESTION}"$'\e[0m\e['"${len}"'D' > /dev/tty
        __SHAI_GHOST_VISIBLE=1
    fi
}

# ── Clear suggestion state + erase from screen ──────────────────────────────
__shai_clear_suggestion() {
    __shai_erase_ghost
    __SHAI_SUGGESTION=""
    __SHAI_LAST_BUFFER=""
}

# ── Send async request to daemon ─────────────────────────────────────────────
__shai_send_request() {
    local buffer="$1" cursor_pos="$2"

    [[ -S "$__SHAI_SOCKET" ]] || return 1

    # Build entire JSON request in a single python3 call
    # Pass buffer via env var to avoid shell quoting issues
    local json_req
    json_req=$(__SHAI_BUF="$buffer" __SHAI_CWD="$PWD" python3 -c "
import json, os, sys
hist = [h for h in sys.stdin.read().splitlines() if h]
print(json.dumps({
    'type': 'complete',
    'request_id': 'ac-$RANDOM',
    'buffer': os.environ['__SHAI_BUF'],
    'cursor_pos': $cursor_pos,
    'cwd': os.environ['__SHAI_CWD'],
    'shell': 'zsh',
    'history': hist,
    'exit_status': ${__SHAI_LAST_EXIT:-0},
}))
" < <(fc -l -5 -1 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//') 2>/dev/null)

    [[ -z "$json_req" ]] && return 1

    # Close any previous in-flight request
    if [[ -n "$__SHAI_RESPONSE_FD" ]]; then
        zle -F $__SHAI_RESPONSE_FD 2>/dev/null
        exec {__SHAI_RESPONSE_FD}<&- 2>/dev/null
        __SHAI_RESPONSE_FD=""
    fi

    # Connect via zsh native socket
    zmodload zsh/net/socket 2>/dev/null || return 1
    if ! zsocket "$__SHAI_SOCKET" 2>/dev/null; then
        return 1
    fi
    __SHAI_RESPONSE_FD=$REPLY

    print -u $__SHAI_RESPONSE_FD "$json_req"

    # Watch for response
    zle -F $__SHAI_RESPONSE_FD __shai_on_response
}

# ── Handle async response ────────────────────────────────────────────────────
__shai_on_response() {
    local fd="$1"

    local response=""
    if ! read -r -u $fd response 2>/dev/null; then
        zle -F $fd
        exec {fd}<&- 2>/dev/null
        __SHAI_RESPONSE_FD=""
        return
    fi

    zle -F $fd
    exec {fd}<&- 2>/dev/null
    __SHAI_RESPONSE_FD=""

    # Extract suggestion (pure shell)
    local suggestion=""
    if [[ "$response" == *'"suggestion": "'* ]]; then
        suggestion="${response#*\"suggestion\": \"}"
        suggestion="${suggestion%%\"*}"
        suggestion="${suggestion//\\n/$'\n'}"
        suggestion="${suggestion//\\\\/\\}"
    fi

    [[ -z "$suggestion" ]] && return
    (( ${#suggestion} > 200 )) && return

    # Filter out LLM artifacts (markdown, prose, multiline)
    [[ "$suggestion" == *'```'* ]] && return
    [[ "$suggestion" == *$'\n'* ]] && return
    [[ "$suggestion" == *"don't"* ]] && return
    [[ "$suggestion" == *"cannot"* ]] && return
    [[ "$suggestion" == *"I "* ]] && return
    [[ "$suggestion" == *"Sorry"* ]] && return

    __SHAI_SUGGESTION="$suggestion"
    __SHAI_LAST_BUFFER="$__SHAI_PENDING_BUFFER"
    __shai_draw_ghost
}

# ── Debounce ─────────────────────────────────────────────────────────────────
__shai_schedule_complete() {
    __shai_cancel_debounce

    local buffer="$BUFFER"
    local cursor_pos="$CURSOR"

    (( ${#buffer} < __SHAI_MIN_CHARS )) && return

    # Prefix reuse
    if [[ -n "$__SHAI_SUGGESTION" && -n "$__SHAI_LAST_BUFFER" ]]; then
        if [[ "$buffer" == "${__SHAI_LAST_BUFFER}"* ]]; then
            local typed_extra="${buffer#${__SHAI_LAST_BUFFER}}"
            if [[ "$__SHAI_SUGGESTION" == "${typed_extra}"* ]]; then
                __SHAI_SUGGESTION="${__SHAI_SUGGESTION#${typed_extra}}"
                __SHAI_LAST_BUFFER="$buffer"
                __shai_draw_ghost
                return
            fi
        fi
    fi

    __SHAI_SUGGESTION=""
    __SHAI_LAST_BUFFER=""

    # Adaptive debounce
    local delay_ms=$__SHAI_DELAY
    (( ${#buffer} >= __SHAI_DELAY_THRESHOLD )) && delay_ms=$__SHAI_DELAY_SHORT
    local delay_s
    delay_s=$(printf '0.%03d' "$delay_ms")

    __SHAI_PENDING_BUFFER="$buffer"
    __SHAI_PENDING_CURSOR=$cursor_pos

    exec {__SHAI_TIMER_FD}< <(sleep "$delay_s" && echo fire)
    zle -F $__SHAI_TIMER_FD __shai_debounce_fired
}

__shai_debounce_fired() {
    local fd="$1" dummy
    read -r dummy <&$fd 2>/dev/null
    zle -F $fd
    exec {fd}<&-
    __SHAI_TIMER_FD=""
    __shai_send_request "$__SHAI_PENDING_BUFFER" "$__SHAI_PENDING_CURSOR"
}

__shai_cancel_debounce() {
    if [[ -n "$__SHAI_TIMER_FD" ]]; then
        zle -F $__SHAI_TIMER_FD 2>/dev/null
        exec {__SHAI_TIMER_FD}<&- 2>/dev/null
        __SHAI_TIMER_FD=""
    fi
}

# ── Accept full suggestion (→) ───────────────────────────────────────────────
__shai_accept_suggestion() {
    if [[ -n "$__SHAI_SUGGESTION" ]]; then
        __shai_erase_ghost
        BUFFER="${BUFFER}${__SHAI_SUGGESTION}"
        CURSOR=${#BUFFER}
        __SHAI_SUGGESTION=""
        __SHAI_LAST_BUFFER=""
    else
        zle forward-char
    fi
}

# ── Dismiss suggestion (Esc) ─────────────────────────────────────────────────
__shai_dismiss() {
    if [[ -n "$__SHAI_SUGGESTION" ]]; then
        __shai_clear_suggestion
        __shai_cancel_debounce
    fi
}

# ── Accept one word (Shift+→) ───────────────────────────────────────────────
__shai_accept_word() {
    if [[ -n "$__SHAI_SUGGESTION" ]]; then
        __shai_erase_ghost
        __shai_cancel_debounce
        if [[ -n "$__SHAI_RESPONSE_FD" ]]; then
            zle -F $__SHAI_RESPONSE_FD 2>/dev/null
            exec {__SHAI_RESPONSE_FD}<&- 2>/dev/null
            __SHAI_RESPONSE_FD=""
        fi
        local first_word="${__SHAI_SUGGESTION%% *}"
        local rest="${__SHAI_SUGGESTION#* }"
        if [[ "$first_word" == "$__SHAI_SUGGESTION" ]]; then
            __shai_accept_suggestion
            return
        fi
        BUFFER="${BUFFER}${first_word} "
        CURSOR=${#BUFFER}
        __SHAI_SUGGESTION="$rest"
        __SHAI_LAST_BUFFER="$BUFFER"
        zle -R
        __shai_draw_ghost
    else
        zle forward-char
    fi
}

# ── Tab: accept or native complete ───────────────────────────────────────────
__shai_tab_accept() {
    if [[ -n "$__SHAI_SUGGESTION" ]]; then
        __shai_accept_suggestion
    else
        zle expand-or-complete
    fi
}

# ── Self-insert ──────────────────────────────────────────────────────────────
__shai_self_insert() {
    __shai_clear_suggestion
    zle .self-insert
    __shai_schedule_complete
}

# ── Backspace ────────────────────────────────────────────────────────────────
__shai_backward_delete() {
    __shai_clear_suggestion
    zle .backward-delete-char
    if (( ${#BUFFER} >= __SHAI_MIN_CHARS )); then
        __shai_schedule_complete
    fi
}

# ── Enter: clean up before execution ─────────────────────────────────────────
__shai_line_finish() {
    __shai_clear_suggestion
    __shai_cancel_debounce
    if [[ -n "$__SHAI_RESPONSE_FD" ]]; then
        zle -F $__SHAI_RESPONSE_FD 2>/dev/null
        exec {__SHAI_RESPONSE_FD}<&- 2>/dev/null
        __SHAI_RESPONSE_FD=""
    fi
    zle .accept-line
}

# ── Register widgets ─────────────────────────────────────────────────────────
zle -N __shai_self_insert
zle -N __shai_backward_delete
zle -N __shai_accept_suggestion
zle -N __shai_accept_word
zle -N __shai_tab_accept
zle -N __shai_line_finish
zle -N __shai_dismiss

# ── Keybindings ──────────────────────────────────────────────────────────────
bindkey -M main -R ' '-'~' __shai_self_insert   # All printable chars
bindkey '^?' __shai_backward_delete              # Backspace
bindkey '^[[C' __shai_accept_suggestion          # Right arrow — accept full
bindkey '^[[1;2C' __shai_accept_word             # Shift+Right — accept word
bindkey '\t' __shai_tab_accept                   # Tab
bindkey '^M' __shai_line_finish                  # Enter
bindkey '\e' __shai_dismiss                      # Esc — dismiss suggestion
