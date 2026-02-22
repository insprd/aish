"""Prompt templates for all ghst request types.

All prompts instruct the LLM to return ONLY the completion/command/fix —
no explanation, no markdown, no commentary. Empty string if unsure.
"""

from __future__ import annotations

import platform


def _os_info() -> str:
    """Return a short OS identifier for the system prompt."""
    system = platform.system().lower()
    if system == "darwin":
        return "macOS"
    if system == "linux":
        try:
            import distro  # type: ignore[import-untyped]
            return f"Linux ({distro.name()})"
        except ImportError:
            return "Linux"
    return system


AUTOCOMPLETE_SYSTEM = f"""\
You are a shell command autocomplete engine on {_os_info()}.
You will receive partial command-line input. Your job is to continue the text \
from exactly where it left off — like pressing Tab.
RULES:
- Output ONLY the characters that come after the provided text
- This is pure text continuation, not instruction following
- Include leading whitespace when the next token is a new argument
- Do NOT repeat any part of the input
- Do NOT explain, comment, or wrap in markdown
- If no useful continuation exists, output nothing"""


COMMAND_SYSTEM = f"""\
You are an expert shell assistant. The user is on {_os_info()}.
You help with shell commands — corrections, generation, and search.
RULES:
- Return ONLY the requested output (command, fix, etc.)
- NO explanations, NO markdown, NO commentary
- If unsure, return an empty string
- Never suggest commands that would be destructive without clear user intent
- Preserve the user's command style (quoting, flag style, etc.)"""


def autocomplete_system() -> str:
    return AUTOCOMPLETE_SYSTEM


def autocomplete_user(
    buffer: str,
    cwd: str,
    history: list[str],
    shell: str = "zsh",
    exit_status: int = 0,
) -> str:
    hist_text = "\n".join(history[-5:]) if history else "(none)"
    return f"""\
Context: {shell} shell in {cwd}
Recent commands:
{hist_text}
Last exit: {exit_status}

Complete: {buffer}"""


def proactive_system(session_buffer: str = "") -> str:
    base = COMMAND_SYSTEM
    if session_buffer:
        base += f"\n\nRecent session:\n{session_buffer}"
    return base


def proactive_user(
    cwd: str,
    history: list[str],
    last_command: str,
    last_output: str,
    shell: str = "zsh",
) -> str:
    hist_text = "\n".join(history[-5:]) if history else "(none)"
    return f"""\
Shell: {shell}
Working directory: {cwd}
Recent commands:
{hist_text}

Last command: {last_command}
Its output (last 50 lines):
{last_output}

The user's prompt is empty. Suggest the single most likely next command they would want to run.
Return ONLY the command. Return an empty string if nothing is clearly suggested."""


def nl_command_user(
    prompt: str,
    cwd: str,
    buffer: str = "",
    history: list[str] | None = None,
    shell: str = "zsh",
) -> str:
    hist_text = "\n".join((history or [])[-10:]) if history else "(none)"
    context = ""
    if buffer:
        context = f"\nPartial command already typed: {buffer!r}"
    return f"""\
Shell: {shell}
Working directory: {cwd}
Recent commands:
{hist_text}
{context}
User request: {prompt}

Generate ONLY the shell command. No explanation."""


def error_correction_user(
    failed_command: str,
    exit_status: int,
    stderr: str,
    cwd: str,
    shell: str = "zsh",
) -> str:
    return f"""\
Shell: {shell}
Working directory: {cwd}

Failed command: {failed_command}
Exit status: {exit_status}
Error output:
{stderr}

Return ONLY the corrected command. If you can't determine the fix, return an empty string."""


def history_search_user(
    query: str,
    history: list[str],
    shell: str = "zsh",
) -> str:
    hist_text = "\n".join(history)
    return f"""\
Shell: {shell}

User is searching their history for: {query}

Shell history (most recent last):
{hist_text}

Return a JSON array of the most relevant commands, ranked by relevance.
Format: [{{"command": "...", "score": 0.95}}, ...]
Return at most 10 results. Only include commands that match the user's intent.
If nothing matches, return an empty array: []"""
