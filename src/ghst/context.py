"""Context gathering and caching for ghst.

Gathers cwd, git status, environment info, and caches results to avoid
redundant work across rapid-fire autocomplete requests.
"""

from __future__ import annotations

import os
import subprocess
import time
from dataclasses import dataclass


@dataclass
class ContextInfo:
    """Cached context information about the user's environment."""

    cwd: str = ""
    git_branch: str = ""
    git_dirty: bool = False
    os_name: str = ""
    shell: str = ""
    _cache_time: float = 0.0
    _cache_cwd: str = ""

    # Cache TTL in seconds
    CACHE_TTL: float = 5.0

    def gather(self, cwd: str, shell: str = "zsh") -> ContextInfo:
        """Gather context, using cache if fresh and same cwd."""
        now = time.monotonic()
        if (
            self._cache_cwd == cwd
            and (now - self._cache_time) < self.CACHE_TTL
        ):
            self.shell = shell
            return self

        self.cwd = cwd
        self.shell = shell
        self.os_name = os.uname().sysname
        self._gather_git(cwd)
        self._cache_time = now
        self._cache_cwd = cwd
        return self

    def _gather_git(self, cwd: str) -> None:
        """Gather git branch and dirty status."""
        try:
            result = subprocess.run(
                ["git", "rev-parse", "--abbrev-ref", "HEAD"],
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=1,
            )
            if result.returncode == 0:
                self.git_branch = result.stdout.strip()
            else:
                self.git_branch = ""
                self.git_dirty = False
                return

            result = subprocess.run(
                ["git", "status", "--porcelain"],
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=1,
            )
            self.git_dirty = bool(result.stdout.strip())
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            self.git_branch = ""
            self.git_dirty = False

    def summary(self) -> str:
        """Return a short context summary for inclusion in prompts."""
        parts = [f"cwd: {self.cwd}"]
        if self.git_branch:
            status = " (dirty)" if self.git_dirty else ""
            parts.append(f"git: {self.git_branch}{status}")
        return ", ".join(parts)
