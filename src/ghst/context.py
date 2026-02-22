"""Context gathering and caching for ghst.

Gathers cwd, git status, environment info, and caches results to avoid
redundant work across rapid-fire autocomplete requests.
"""

from __future__ import annotations

import os
import subprocess
import time
from dataclasses import dataclass, field

# Project marker files → short project type label
_PROJECT_MARKERS: dict[str, str] = {
    "package.json": "node",
    "pyproject.toml": "python",
    "Cargo.toml": "rust",
    "go.mod": "go",
    "Gemfile": "ruby",
    "Makefile": "make",
    "Dockerfile": "docker",
    "docker-compose.yml": "docker-compose",
    "docker-compose.yaml": "docker-compose",
    "Taskfile.yml": "task",
    "justfile": "just",
    "CMakeLists.txt": "cmake",
    "pom.xml": "maven",
    "build.gradle": "gradle",
}


@dataclass
class ContextInfo:
    """Cached context information about the user's environment."""

    cwd: str = ""
    git_branch: str = ""
    git_dirty: bool = False
    git_branches: list[str] = field(default_factory=list)
    project_types: list[str] = field(default_factory=list)
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
        self._detect_project_types(cwd)
        self._cache_time = now
        self._cache_cwd = cwd
        return self

    def _gather_git(self, cwd: str) -> None:
        """Gather git branch, dirty status, and local branches."""
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
                self.git_branches = []
                return

            result = subprocess.run(
                ["git", "status", "--porcelain"],
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=1,
            )
            self.git_dirty = bool(result.stdout.strip())

            result = subprocess.run(
                ["git", "branch", "--format=%(refname:short)"],
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=1,
            )
            if result.returncode == 0:
                branches = result.stdout.strip().splitlines()
                # Exclude current branch, cap at 20
                self.git_branches = [
                    b for b in branches if b != self.git_branch
                ][:20]
            else:
                self.git_branches = []
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            self.git_branch = ""
            self.git_dirty = False
            self.git_branches = []

    def _detect_project_types(self, cwd: str) -> None:
        """Detect project type from marker files in cwd."""
        found: list[str] = []
        try:
            entries = set(os.listdir(cwd))
        except OSError:
            self.project_types = []
            return
        for filename, label in _PROJECT_MARKERS.items():
            if filename in entries and label not in found:
                found.append(label)
        self.project_types = found

    def dir_listing(self, cwd: str, max_entries: int = 30) -> str:
        """Return a compact listing of entries in cwd for prompt context."""
        try:
            entries = sorted(os.listdir(cwd))
        except OSError:
            return ""
        items: list[str] = []
        for name in entries:
            if name.startswith("."):
                continue
            full = os.path.join(cwd, name)
            suffix = "/" if os.path.isdir(full) else ""
            items.append(f"{name}{suffix}")
            if len(items) >= max_entries:
                break
        return "  ".join(items)

    @staticmethod
    def active_env() -> str:
        """Return a short description of active dev environments."""
        parts: list[str] = []
        venv = os.environ.get("VIRTUAL_ENV")
        if venv:
            parts.append(f"venv:{os.path.basename(venv)}")
        conda = os.environ.get("CONDA_DEFAULT_ENV")
        if conda:
            parts.append(f"conda:{conda}")
        node = os.environ.get("NODE_ENV")
        if node:
            parts.append(f"node_env:{node}")
        return ", ".join(parts)

    def summary(self) -> str:
        """Return a short context summary for inclusion in prompts."""
        parts = [f"cwd: {self.cwd}"]
        if self.git_branch:
            status = " (dirty)" if self.git_dirty else ""
            parts.append(f"git: {self.git_branch}{status}")
        return ", ".join(parts)
