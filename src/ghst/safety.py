"""Safety checks for ghst.

Dangerous command detection and history/output sanitization before LLM calls.
"""

from __future__ import annotations

import re

# Patterns that indicate dangerous commands
DANGEROUS_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\brm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+|--force\s+).*(/|~|\$HOME)", re.IGNORECASE),
     "Recursive force-delete on important path"),
    (re.compile(r"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\s+/\s*$"),
     "rm -rf /"),
    (re.compile(r"\bmkfs\b"),
     "Filesystem format"),
    (re.compile(r"\bdd\s+if="),
     "Raw disk write"),
    (re.compile(r":\(\)\s*\{\s*:\|:&\s*\}\s*;"),
     "Fork bomb"),
    (re.compile(r"\bchmod\s+(-[a-zA-Z]*R[a-zA-Z]*\s+)?[0-7]*777\s+/"),
     "Recursive chmod 777 on root"),
    (re.compile(r"\bchown\s+-[a-zA-Z]*R"),
     "Recursive chown"),
    (re.compile(r">\s*/dev/sd[a-z]"),
     "Direct write to block device"),
    (re.compile(r"\bcurl\b.*\|\s*(sudo\s+)?(ba)?sh"),
     "Pipe curl to shell"),
    (re.compile(r"\bwget\b.*\|\s*(sudo\s+)?(ba)?sh"),
     "Pipe wget to shell"),
]

# Patterns to sanitize from history/output before sending to LLM
SECRET_PATTERNS: list[re.Pattern[str]] = [
    # API keys and tokens
    re.compile(r"(sk-[a-zA-Z0-9_-]{20,})", re.IGNORECASE),
    re.compile(r"(sk-ant-[a-zA-Z0-9_-]{20,})", re.IGNORECASE),
    re.compile(r"(ghp_[a-zA-Z0-9]{36,})", re.IGNORECASE),
    re.compile(r"(gho_[a-zA-Z0-9]{36,})", re.IGNORECASE),
    re.compile(r"(xoxb-[a-zA-Z0-9-]+)", re.IGNORECASE),
    re.compile(r"(xoxp-[a-zA-Z0-9-]+)", re.IGNORECASE),
    # Generic patterns
    re.compile(r"(api[_-]?key\s*[=:]\s*)['\"]?([a-zA-Z0-9_-]{16,})['\"]?", re.IGNORECASE),
    re.compile(r"(token\s*[=:]\s*)['\"]?([a-zA-Z0-9_-]{16,})['\"]?", re.IGNORECASE),
    re.compile(r"(password\s*[=:]\s*)['\"]?(\S+)['\"]?", re.IGNORECASE),
    re.compile(r"(secret\s*[=:]\s*)['\"]?([a-zA-Z0-9_-]{16,})['\"]?", re.IGNORECASE),
    # AWS
    re.compile(r"(AKIA[A-Z0-9]{16})", re.IGNORECASE),
    # Bearer tokens in headers
    re.compile(r"(Bearer\s+)[a-zA-Z0-9._-]{20,}", re.IGNORECASE),
]


def check_dangerous(command: str) -> str | None:
    """Check if a command matches any dangerous pattern.

    Returns a warning message if dangerous, None if safe.
    """
    for pattern, description in DANGEROUS_PATTERNS:
        if pattern.search(command):
            return f"⚠️  {description}"
    return None


def sanitize_text(text: str) -> str:
    """Remove secrets and sensitive data from text before sending to LLM."""
    result = text
    for pattern in SECRET_PATTERNS:
        if pattern.groups == 0 or pattern.groups == 1:
            result = pattern.sub("[REDACTED]", result)
        else:
            # For patterns with capture groups (prefix + secret), keep prefix
            result = pattern.sub(r"\1[REDACTED]", result)
    return result


def sanitize_history(history: list[str]) -> list[str]:
    """Sanitize a list of history commands."""
    return [sanitize_text(cmd) for cmd in history]


def sanitize_output(output: str) -> str:
    """Sanitize terminal output before sending to LLM."""
    return sanitize_text(output)
