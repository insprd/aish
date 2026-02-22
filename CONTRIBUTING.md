# Contributing to ghst

Thanks for your interest in contributing! Here's how to get started.

## Development Setup

```bash
git clone https://github.com/insprd/ghst.git
cd ghst
uv venv && source .venv/bin/activate
uv pip install -e ".[dev]"
```

## Running Tests and Checks

```bash
uv run python -m pytest          # Run tests
uv run ruff check src/           # Lint
uv run basedpyright src/ghst/    # Type check
```

All three must pass before submitting a PR.

## Code Style

- **Formatter/linter:** [Ruff](https://docs.astral.sh/ruff/) — config in `pyproject.toml`
- **Type checker:** [basedpyright](https://github.com/DetachHead/basedpyright) in standard mode
- **Line length:** 100 characters
- **Python:** 3.10+ (use `from __future__ import annotations` where needed)
- Keep changes minimal and focused — one concern per PR

## Submitting a Pull Request

1. Fork the repo and create a feature branch from `main`
2. Make your changes
3. Run `uv run python -m pytest && uv run ruff check src/ && uv run basedpyright src/ghst/`
4. Open a PR with a clear description of what changed and why

## Reporting Issues

- Search existing issues first to avoid duplicates
- Include your OS, zsh version, Python version, and terminal emulator
- For bugs, include steps to reproduce and any relevant error output

## Architecture Overview

See [README.md](README.md#architecture) for the two-process design (zsh ZLE ↔ Python daemon over Unix socket). The `docs/` folder has additional design documents.
