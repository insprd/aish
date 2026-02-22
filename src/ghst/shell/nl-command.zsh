# nl-command.zsh — Natural language command construction (Ctrl+G)
#
# Opens an inline prompt where the user describes what they want in English.
# The LLM generates a shell command and places it in the buffer for review.

# ── Undo state ──────────────────────────────────────────────────────────────
typeset -g __GHST_SAVED_BUFFER=""
typeset -gi __GHST_SAVED_CURSOR=0

# ── Colors (configurable via config.toml, fallback to ANSI defaults) ────────
typeset -g __GHST_C_ACCENT="${__GHST_ACCENT_ESC:-$'\e[36m'}"
typeset -g __GHST_C_SUCCESS="${__GHST_SUCCESS_ESC:-$'\e[32m'}"
typeset -g __GHST_C_WARNING="${__GHST_WARNING_ESC:-$'\e[33m'}"
typeset -g __GHST_C_ERROR="${__GHST_ERROR_ESC:-$'\e[31m'}"
typeset -g __GHST_C_DIM=$'\e[2m'
typeset -g __GHST_C_RESET=$'\e[0m'

# ── Spinner ─────────────────────────────────────────────────────────────────
typeset -g __GHST_SPINNER_PID=0

__ghst_start_spinner() {
    local label="${1:-thinking}"
    (
        trap 'printf "\r\e[2K" > /dev/tty; exit 0' TERM INT
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            printf '\r  %s %s %s%s%s' \
                "${__GHST_C_ACCENT}" "${frames[$((i % 10 + 1))]}" \
                "${__GHST_C_DIM}${label}...${__GHST_C_RESET}" \
                "" "" > /dev/tty
            sleep 0.08
            (( i++ ))
        done
    ) &!
    __GHST_SPINNER_PID=$!
}

__ghst_stop_spinner() {
    if (( __GHST_SPINNER_PID > 0 )); then
        kill $__GHST_SPINNER_PID 2>/dev/null
        wait $__GHST_SPINNER_PID 2>/dev/null
        __GHST_SPINNER_PID=0
        printf '\r\e[2K' > /dev/tty
    fi
}

# ── NL Command Widget ───────────────────────────────────────────────────────
__ghst_nl_command() {
    # Save current buffer for undo
    local saved_buffer="$BUFFER"
    local saved_cursor=$CURSOR

    # Clear any ghost text
    __ghst_clear_suggestion 2>/dev/null

    # Show context hint if buffer has content
    local context_hint=""
    if [[ -n "$BUFFER" ]]; then
        local short_buffer="${BUFFER:0:40}"
        [[ ${#BUFFER} -gt 40 ]] && short_buffer="${short_buffer}..."
        context_hint="${__GHST_C_DIM}($short_buffer)${__GHST_C_RESET} "
    fi

    # Use recursive-edit for full line editing (arrow keys, Ctrl+A/E, etc.)
    local orig_prompt="$PROMPT"
    PROMPT="${__GHST_C_ACCENT}ghst>${__GHST_C_RESET} ${context_hint}"
    BUFFER=""
    CURSOR=0
    POSTDISPLAY=""
    zle reset-prompt
    zle recursive-edit
    local edit_status=$?

    local nl_input="$BUFFER"
    PROMPT="$orig_prompt"

    # Handle cancel (Ctrl+C or empty)
    if (( edit_status != 0 )) || [[ -z "$nl_input" ]]; then
        BUFFER="$saved_buffer"
        CURSOR=$saved_cursor
        zle reset-prompt
        return
    fi

    # Show animated spinner
    BUFFER=""
    POSTDISPLAY=""
    zle reset-prompt
    __ghst_start_spinner "thinking"

    # Build request
    local history_json
    history_json=$(python3 -c "
import json
history = '''$(__ghst_get_history)'''.strip().split('\n')
history = [h for h in history if h]
print(json.dumps(history[-10:]))
" 2>/dev/null)
    [[ -z "$history_json" ]] && history_json='[]'

    local escaped_prompt escaped_buffer
    escaped_prompt=$(python3 -c "import json; print(json.dumps('''$nl_input'''))" 2>/dev/null)
    escaped_buffer=$(python3 -c "import json; print(json.dumps('$saved_buffer'))" 2>/dev/null)

    local json_request="{\"type\":\"nl\",\"prompt\":$escaped_prompt,\"buffer\":$escaped_buffer,\"cwd\":\"$PWD\",\"shell\":\"zsh\",\"history\":$history_json}"

    # Send synchronous request (user is waiting)
    local response
    response=$(__ghst_request "$json_request")

    # Stop spinner
    __ghst_stop_spinner

    if [[ -z "$response" ]]; then
        BUFFER="$saved_buffer"
        CURSOR=$saved_cursor
        POSTDISPLAY=$'\n'"  ${__GHST_C_ERROR}✗${__GHST_C_RESET} ${__GHST_C_DIM}couldn't reach daemon — run 'ghst start'${__GHST_C_RESET}"
        zle reset-prompt
        return
    fi

    # Parse response
    local command warning
    command=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('command', ''))
except: pass
" <<< "$response")

    warning=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('warning', ''))
except: pass
" <<< "$response")

    if [[ -z "$command" ]]; then
        BUFFER="$saved_buffer"
        CURSOR=$saved_cursor
        POSTDISPLAY=$'\n'"  ${__GHST_C_WARNING}⚠${__GHST_C_RESET} ${__GHST_C_DIM}couldn't generate a command${__GHST_C_RESET}"
        zle reset-prompt
        return
    fi

    # Save for undo (Ctrl+Z)
    __GHST_SAVED_BUFFER="$saved_buffer"
    __GHST_SAVED_CURSOR=$saved_cursor

    # Place generated command in buffer
    BUFFER="$command"
    CURSOR=${#BUFFER}

    # Show success hint (with warning if present)
    local hint="${__GHST_C_SUCCESS}✓${__GHST_C_RESET} ${__GHST_C_DIM}Ctrl+Z to undo${__GHST_C_RESET}"
    if [[ -n "$warning" ]]; then
        POSTDISPLAY=$'\n'"  ${__GHST_C_WARNING}⚠ ${warning}${__GHST_C_RESET}"$'\n'"  ${hint}"
    else
        POSTDISPLAY=$'\n'"  ${hint}"
    fi

    zle reset-prompt
}
zle -N __ghst_nl_command

# ── History Search Widget (Ctrl+R) ──────────────────────────────────────────
__ghst_history_search() {
    local saved_buffer="$BUFFER"
    local saved_cursor=$CURSOR

    # Clear ghost text
    __ghst_clear_suggestion 2>/dev/null

    # Use recursive-edit for search query input
    local orig_prompt="$PROMPT"
    PROMPT="${__GHST_C_ACCENT}ghst history>${__GHST_C_RESET} "
    BUFFER=""
    CURSOR=0
    POSTDISPLAY=""
    zle reset-prompt
    zle recursive-edit
    local edit_status=$?

    local query="$BUFFER"
    PROMPT="$orig_prompt"

    if (( edit_status != 0 )) || [[ -z "$query" ]]; then
        BUFFER="$saved_buffer"
        CURSOR=$saved_cursor
        zle reset-prompt
        return
    fi

    # Show animated spinner
    BUFFER=""
    POSTDISPLAY=""
    zle reset-prompt
    __ghst_start_spinner "searching"

    # Get history entries (deduplicated)
    local history_json
    history_json=$(python3 -c "
import json
history = []
seen = set()
lines = '''$(__ghst_get_history)'''.strip().split('\n')
for l in lines:
    l = l.strip()
    if l and l not in seen:
        seen.add(l)
        history.append(l)
print(json.dumps(history[-500:]))
" 2>/dev/null)
    [[ -z "$history_json" ]] && history_json='[]'

    local escaped_query
    escaped_query=$(printf '%s' "$query" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null)

    local json_request="{\"type\":\"history_search\",\"query\":$escaped_query,\"history\":$history_json,\"shell\":\"zsh\"}"

    local response
    response=$(__ghst_request "$json_request")

    # Stop spinner
    __ghst_stop_spinner

    if [[ -z "$response" ]]; then
        BUFFER="$saved_buffer"
        CURSOR=$saved_cursor
        POSTDISPLAY=$'\n'"  ${__GHST_C_ERROR}✗${__GHST_C_RESET} ${__GHST_C_DIM}couldn't reach daemon${__GHST_C_RESET}"
        zle reset-prompt
        return
    fi

    # Parse first result
    local first_cmd
    first_cmd=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    results = d.get('results', [])
    if results:
        r = results[0]
        print(r.get('command', '') if isinstance(r, dict) else str(r))
except: pass
" <<< "$response")

    if [[ -n "$first_cmd" ]]; then
        __GHST_SAVED_BUFFER="$saved_buffer"
        __GHST_SAVED_CURSOR=$saved_cursor
        BUFFER="$first_cmd"
        CURSOR=${#BUFFER}
        POSTDISPLAY=$'\n'"  ${__GHST_C_SUCCESS}✓${__GHST_C_RESET} ${__GHST_C_DIM}Ctrl+Z to undo${__GHST_C_RESET}"
    else
        BUFFER="$saved_buffer"
        CURSOR=$saved_cursor
        POSTDISPLAY=$'\n'"  ${__GHST_C_WARNING}⚠${__GHST_C_RESET} ${__GHST_C_DIM}no matching history found${__GHST_C_RESET}"
    fi

    zle reset-prompt
}
zle -N __ghst_history_search

# ── Undo: restore original buffer before NL/history ─────────────────────────
__ghst_nl_undo() {
    if [[ -n "$__GHST_SAVED_BUFFER" ]]; then
        BUFFER="$__GHST_SAVED_BUFFER"
        CURSOR=$__GHST_SAVED_CURSOR
        __GHST_SAVED_BUFFER=""
        POSTDISPLAY=""
        zle reset-prompt
    else
        zle undo
    fi
}
zle -N __ghst_nl_undo

# ── Keybindings ──────────────────────────────────────────────────────────────
bindkey '^G' __ghst_nl_command        # Ctrl+G — NL command
bindkey '^R' __ghst_history_search    # Ctrl+R — History search
bindkey '^Z' __ghst_nl_undo           # Ctrl+Z — Undo NL command
