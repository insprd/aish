# autocomplete.zsh — ZLE ghost text widget
# Inline suggestions rendered via direct terminal escape codes

# ── State ────────────────────────────────────────────────────────────────────
typeset -g __AISH_SUGGESTION=""
typeset -g __AISH_TIMER_FD=""
typeset -g __AISH_LAST_BUFFER=""
typeset -g __AISH_PENDING_BUFFER=""
typeset -gi __AISH_PENDING_CURSOR=0
typeset -gi __AISH_GHOST_VISIBLE=0
typeset -g __AISH_RESPONSE_FD=""

# ── Configuration ────────────────────────────────────────────────────────────
typeset -gi __AISH_DELAY=${__AISH_DELAY:-200}
typeset -gi __AISH_DELAY_SHORT=${__AISH_DELAY_SHORT:-100}
typeset -gi __AISH_DELAY_THRESHOLD=${__AISH_DELAY_THRESHOLD:-8}
typeset -gi __AISH_MIN_CHARS=${__AISH_MIN_CHARS:-3}

# ── Erase ghost text from terminal ───────────────────────────────────────────
__aish_erase_ghost() {
    if (( __AISH_GHOST_VISIBLE )); then
        echo -n $'\e[0K' > /dev/tty
        __AISH_GHOST_VISIBLE=0
    fi
}

# ── Draw ghost text at cursor position ───────────────────────────────────────
__aish_draw_ghost() {
    if [[ -n "$__AISH_SUGGESTION" ]]; then
        local len=${#__AISH_SUGGESTION}
        # Print gray text, then move cursor back
        echo -n $'\e[90m'"${__AISH_SUGGESTION}"$'\e[0m\e['"${len}"'D' > /dev/tty
        __AISH_GHOST_VISIBLE=1
    fi
}

# ── Clear suggestion state + erase from screen ──────────────────────────────
__aish_clear_suggestion() {
    __aish_erase_ghost
    __AISH_SUGGESTION=""
    __AISH_LAST_BUFFER=""
}

# ── Send async request to daemon ─────────────────────────────────────────────
__aish_send_request() {
    local buffer="$1" cursor_pos="$2"

    [[ -S "$__AISH_SOCKET" ]] || return 1

    # Build entire JSON request in a single python3 call
    # Pass buffer via env var to avoid shell quoting issues
    local json_req
    json_req=$(__AISH_BUF="$buffer" __AISH_CWD="$PWD" python3 -c "
import json, os, sys
hist = [h for h in sys.stdin.read().splitlines() if h]
print(json.dumps({
    'type': 'complete',
    'request_id': 'ac-$RANDOM',
    'buffer': os.environ['__AISH_BUF'],
    'cursor_pos': $cursor_pos,
    'cwd': os.environ['__AISH_CWD'],
    'shell': 'zsh',
    'history': hist,
    'exit_status': ${__AISH_LAST_EXIT:-0},
}))
" < <(fc -l -5 -1 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//') 2>/dev/null)

    [[ -z "$json_req" ]] && return 1

    # Close any previous in-flight request
    if [[ -n "$__AISH_RESPONSE_FD" ]]; then
        zle -F $__AISH_RESPONSE_FD 2>/dev/null
        exec {__AISH_RESPONSE_FD}<&- 2>/dev/null
        __AISH_RESPONSE_FD=""
    fi

    # Connect via zsh native socket
    zmodload zsh/net/socket 2>/dev/null || return 1
    if ! zsocket "$__AISH_SOCKET" 2>/dev/null; then
        return 1
    fi
    __AISH_RESPONSE_FD=$REPLY

    print -u $__AISH_RESPONSE_FD "$json_req"

    # Watch for response
    zle -F $__AISH_RESPONSE_FD __aish_on_response
}

# ── Handle async response ────────────────────────────────────────────────────
__aish_on_response() {
    local fd="$1"

    local response=""
    if ! read -r -u $fd response 2>/dev/null; then
        zle -F $fd
        exec {fd}<&- 2>/dev/null
        __AISH_RESPONSE_FD=""
        return
    fi

    zle -F $fd
    exec {fd}<&- 2>/dev/null
    __AISH_RESPONSE_FD=""

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

    __AISH_SUGGESTION="$suggestion"
    __AISH_LAST_BUFFER="$__AISH_PENDING_BUFFER"
    __aish_draw_ghost
}

# ── Debounce ─────────────────────────────────────────────────────────────────
__aish_schedule_complete() {
    __aish_cancel_debounce

    local buffer="$BUFFER"
    local cursor_pos="$CURSOR"

    (( ${#buffer} < __AISH_MIN_CHARS )) && return

    # Prefix reuse
    if [[ -n "$__AISH_SUGGESTION" && -n "$__AISH_LAST_BUFFER" ]]; then
        if [[ "$buffer" == "${__AISH_LAST_BUFFER}"* ]]; then
            local typed_extra="${buffer#${__AISH_LAST_BUFFER}}"
            if [[ "$__AISH_SUGGESTION" == "${typed_extra}"* ]]; then
                __AISH_SUGGESTION="${__AISH_SUGGESTION#${typed_extra}}"
                __AISH_LAST_BUFFER="$buffer"
                __aish_draw_ghost
                return
            fi
        fi
    fi

    __AISH_SUGGESTION=""
    __AISH_LAST_BUFFER=""

    # Adaptive debounce
    local delay_ms=$__AISH_DELAY
    (( ${#buffer} >= __AISH_DELAY_THRESHOLD )) && delay_ms=$__AISH_DELAY_SHORT
    local delay_s
    delay_s=$(printf '0.%03d' "$delay_ms")

    __AISH_PENDING_BUFFER="$buffer"
    __AISH_PENDING_CURSOR=$cursor_pos

    exec {__AISH_TIMER_FD}< <(sleep "$delay_s" && echo fire)
    zle -F $__AISH_TIMER_FD __aish_debounce_fired
}

__aish_debounce_fired() {
    local fd="$1" dummy
    read -r dummy <&$fd 2>/dev/null
    zle -F $fd
    exec {fd}<&-
    __AISH_TIMER_FD=""
    __aish_send_request "$__AISH_PENDING_BUFFER" "$__AISH_PENDING_CURSOR"
}

__aish_cancel_debounce() {
    if [[ -n "$__AISH_TIMER_FD" ]]; then
        zle -F $__AISH_TIMER_FD 2>/dev/null
        exec {__AISH_TIMER_FD}<&- 2>/dev/null
        __AISH_TIMER_FD=""
    fi
}

# ── Accept full suggestion (→) ───────────────────────────────────────────────
__aish_accept_suggestion() {
    if [[ -n "$__AISH_SUGGESTION" ]]; then
        __aish_erase_ghost
        BUFFER="${BUFFER}${__AISH_SUGGESTION}"
        CURSOR=${#BUFFER}
        __AISH_SUGGESTION=""
        __AISH_LAST_BUFFER=""
    else
        zle forward-char
    fi
}

# ── Dismiss suggestion (Esc) ─────────────────────────────────────────────────
__aish_dismiss() {
    if [[ -n "$__AISH_SUGGESTION" ]]; then
        __aish_clear_suggestion
        __aish_cancel_debounce
    fi
}

# ── Accept one word (Shift+→) ───────────────────────────────────────────────
__aish_accept_word() {
    if [[ -n "$__AISH_SUGGESTION" ]]; then
        __aish_erase_ghost
        __aish_cancel_debounce
        if [[ -n "$__AISH_RESPONSE_FD" ]]; then
            zle -F $__AISH_RESPONSE_FD 2>/dev/null
            exec {__AISH_RESPONSE_FD}<&- 2>/dev/null
            __AISH_RESPONSE_FD=""
        fi
        local first_word="${__AISH_SUGGESTION%% *}"
        local rest="${__AISH_SUGGESTION#* }"
        if [[ "$first_word" == "$__AISH_SUGGESTION" ]]; then
            __aish_accept_suggestion
            return
        fi
        BUFFER="${BUFFER}${first_word} "
        CURSOR=${#BUFFER}
        __AISH_SUGGESTION="$rest"
        __AISH_LAST_BUFFER="$BUFFER"
        zle -R
        __aish_draw_ghost
    else
        zle forward-char
    fi
}

# ── Tab: accept or native complete ───────────────────────────────────────────
__aish_tab_accept() {
    if [[ -n "$__AISH_SUGGESTION" ]]; then
        __aish_accept_suggestion
    else
        zle expand-or-complete
    fi
}

# ── Self-insert ──────────────────────────────────────────────────────────────
__aish_self_insert() {
    __aish_clear_suggestion
    zle .self-insert
    __aish_schedule_complete
}

# ── Backspace ────────────────────────────────────────────────────────────────
__aish_backward_delete() {
    __aish_clear_suggestion
    zle .backward-delete-char
    if (( ${#BUFFER} >= __AISH_MIN_CHARS )); then
        __aish_schedule_complete
    fi
}

# ── Enter: clean up before execution ─────────────────────────────────────────
__aish_line_finish() {
    __aish_clear_suggestion
    __aish_cancel_debounce
    if [[ -n "$__AISH_RESPONSE_FD" ]]; then
        zle -F $__AISH_RESPONSE_FD 2>/dev/null
        exec {__AISH_RESPONSE_FD}<&- 2>/dev/null
        __AISH_RESPONSE_FD=""
    fi
    zle .accept-line
}

# ── Register widgets ─────────────────────────────────────────────────────────
zle -N __aish_self_insert
zle -N __aish_backward_delete
zle -N __aish_accept_suggestion
zle -N __aish_accept_word
zle -N __aish_tab_accept
zle -N __aish_line_finish
zle -N __aish_dismiss

# ── Keybindings ──────────────────────────────────────────────────────────────
bindkey -M main -R ' '-'~' __aish_self_insert   # All printable chars
bindkey '^?' __aish_backward_delete              # Backspace
bindkey '^[[C' __aish_accept_suggestion          # Right arrow — accept full
bindkey '^[[1;2C' __aish_accept_word             # Shift+Right — accept word
bindkey '\t' __aish_tab_accept                   # Tab
bindkey '^M' __aish_line_finish                  # Enter
bindkey '\e' __aish_dismiss                      # Esc — dismiss suggestion
