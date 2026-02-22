# nl-command.zsh — Natural language command construction (Ctrl+G)
#
# Opens an inline prompt where the user describes what they want in English.
# The LLM generates a shell command and places it in the buffer for review.

# ── NL Command Widget ───────────────────────────────────────────────────────
__aish_nl_command() {
    # Save current buffer for undo
    local saved_buffer="$BUFFER"
    local saved_cursor=$CURSOR

    # Clear any ghost text
    __aish_clear_ghost 2>/dev/null

    # Show context hint if buffer has content
    local context_hint=""
    if [[ -n "$BUFFER" ]]; then
        local short_buffer="${BUFFER:0:40}"
        [[ ${#BUFFER} -gt 40 ]] && short_buffer="${short_buffer}..."
        context_hint="($short_buffer) "
    fi

    # Prompt for NL input
    BUFFER=""
    POSTDISPLAY=""
    zle -R

    # Use vared for inline editing
    local nl_input=""
    local prompt_text="aish> ${context_hint}"

    # Temporarily change PS1 for the input
    print -n "\r\e[2K${prompt_text}"
    read -r nl_input

    # Handle empty input (cancel)
    if [[ -z "$nl_input" ]]; then
        BUFFER="$saved_buffer"
        CURSOR=$saved_cursor
        zle -R
        return
    fi

    # Show spinner
    print -n "\r\e[2K${prompt_text}${nl_input}\n  ⠋ thinking..."

    # Build request
    local history_json
    history_json=$(python3 -c "
import json
history = '''$(__aish_get_history)'''.strip().split('\n')
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
    response=$(__aish_request "$json_request")

    # Clear spinner
    print -n "\r\e[2K\e[A\r\e[2K"

    if [[ -z "$response" ]]; then
        print -n "\r\e[2Kaish: couldn't reach daemon — run 'aish start'\r"
        BUFFER="$saved_buffer"
        CURSOR=$saved_cursor
        zle -R
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
        print -n "\r\e[2Kaish: couldn't generate a command\r"
        BUFFER="$saved_buffer"
        CURSOR=$saved_cursor
        zle -R
        return
    fi

    # Place generated command in buffer
    BUFFER="$command"
    CURSOR=${#BUFFER}

    # Show warning if present
    if [[ -n "$warning" ]]; then
        POSTDISPLAY=$'\n\e[33m'"${warning}"$'\e[0m'
    fi

    # Brief highlight to show it's AI-generated (will clear on next redraw)
    zle -R
}
zle -N __aish_nl_command

# ── History Search Widget (Ctrl+R) ──────────────────────────────────────────
__aish_history_search() {
    local saved_buffer="$BUFFER"
    local saved_cursor=$CURSOR

    # Clear ghost text
    __aish_clear_ghost 2>/dev/null

    # Prompt for search query
    BUFFER=""
    POSTDISPLAY=""
    zle -R

    local query=""
    print -n "\r\e[2Kaish history> "
    read -r query

    if [[ -z "$query" ]]; then
        BUFFER="$saved_buffer"
        CURSOR=$saved_cursor
        zle -R
        return
    fi

    print -n "\r\e[2Kaish history> ${query}\n  ⠋ searching..."

    # Get full history
    local history_json
    history_json=$(python3 -c "
import json
history = []
try:
    import subprocess
    result = subprocess.run(['fc', '-l', '1'], capture_output=True, text=True, shell=True)
    if result.returncode == 0:
        for line in result.stdout.strip().split('\n'):
            parts = line.strip().split(None, 1)
            if len(parts) == 2:
                history.append(parts[1])
except: pass
# Fallback: just use recent history
if not history:
    history = '''$(__aish_get_history)'''.strip().split('\n')
history = [h for h in history if h][-500:]
print(json.dumps(history))
" 2>/dev/null)
    [[ -z "$history_json" ]] && history_json='[]'

    local escaped_query
    escaped_query=$(python3 -c "import json; print(json.dumps('''$query'''))" 2>/dev/null)

    local json_request="{\"type\":\"history_search\",\"query\":$escaped_query,\"history\":$history_json,\"shell\":\"zsh\"}"

    local response
    response=$(__aish_request "$json_request")

    # Clear spinner
    print -n "\r\e[2K\e[A\r\e[2K"

    if [[ -z "$response" ]]; then
        print -n "\r\e[2Kaish: couldn't reach daemon\r"
        BUFFER="$saved_buffer"
        CURSOR=$saved_cursor
        zle -R
        return
    fi

    # Parse results
    local results
    results=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    results = d.get('results', [])
    if not results:
        print('')
    else:
        for i, r in enumerate(results[:10]):
            cmd = r.get('command', '') if isinstance(r, dict) else str(r)
            prefix = '→' if i == 0 else ' '
            print(f'  {prefix} {cmd}')
except:
    print('')
" <<< "$response")

    if [[ -z "$results" ]]; then
        print -n "\r\e[2Kaish: no matching history found\r"
        BUFFER="$saved_buffer"
        CURSOR=$saved_cursor
        zle -R
        return
    fi

    # Display results and let user pick the first one
    # (Full fzf-style selection is a stretch goal)
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
        # Show results briefly
        print "$results"
        print "  ↑↓ navigate, Enter to select, Esc to cancel"

        # For now, select the first result
        BUFFER="$first_cmd"
        CURSOR=${#BUFFER}
    else
        BUFFER="$saved_buffer"
        CURSOR=$saved_cursor
    fi

    zle -R
}
zle -N __aish_history_search

# ── Undo: restore original buffer ───────────────────────────────────────────
# Ctrl+Z is handled by zsh's native undo (undo widget)

# ── Keybindings ──────────────────────────────────────────────────────────────
bindkey '^G' __aish_nl_command        # Ctrl+G — NL command
bindkey '^R' __aish_history_search    # Ctrl+R — History search
