"""Tests for prompt templates."""

from __future__ import annotations

from shai.prompts import (
    autocomplete_system,
    autocomplete_user,
    error_correction_user,
    history_search_user,
    nl_command_user,
    proactive_system,
    proactive_user,
)


class TestAutocomplete:
    def test_system_prompt_contains_rules(self) -> None:
        prompt = autocomplete_system()
        assert "ONLY" in prompt
        assert "empty string" in prompt

    def test_user_prompt_includes_buffer(self) -> None:
        prompt = autocomplete_user(buffer="git sta", cwd="/home/user", history=["cd project"])
        assert "git sta" in prompt
        assert "/home/user" in prompt
        assert "cd project" in prompt

    def test_user_prompt_empty_history(self) -> None:
        prompt = autocomplete_user(buffer="ls", cwd="/tmp", history=[])
        assert "(none)" in prompt

    def test_history_limited_to_5(self) -> None:
        history = [f"cmd{i}" for i in range(20)]
        prompt = autocomplete_user(buffer="git", cwd="/", history=history)
        assert "cmd15" in prompt
        assert "cmd0" not in prompt


class TestProactive:
    def test_system_with_session(self) -> None:
        prompt = proactive_system(session_buffer="[1] git status\n    2 files modified")
        assert "git status" in prompt
        assert "2 files modified" in prompt

    def test_system_without_session(self) -> None:
        prompt = proactive_system()
        assert "Recent session" not in prompt

    def test_user_prompt(self) -> None:
        prompt = proactive_user(
            cwd="/project",
            history=["git status"],
            last_command="npm install",
            last_output="found 3 vulnerabilities\nrun `npm audit fix`",
        )
        assert "npm install" in prompt
        assert "npm audit fix" in prompt
        assert "empty" in prompt.lower()


class TestNLCommand:
    def test_basic(self) -> None:
        prompt = nl_command_user(
            prompt="find python files modified today",
            cwd="/project",
        )
        assert "find python files modified today" in prompt
        assert "/project" in prompt

    def test_with_partial_buffer(self) -> None:
        prompt = nl_command_user(
            prompt="mount current dir and run node",
            cwd="/project",
            buffer="docker run -v",
        )
        assert "docker run -v" in prompt
        assert "mount current dir" in prompt


class TestErrorCorrection:
    def test_basic(self) -> None:
        prompt = error_correction_user(
            failed_command="git pussh origin main",
            exit_status=1,
            stderr="git: 'pussh' is not a git command.",
            cwd="/project",
        )
        assert "git pussh" in prompt
        assert "not a git command" in prompt


class TestHistorySearch:
    def test_basic(self) -> None:
        prompt = history_search_user(
            query="docker postgres command",
            history=["docker run postgres", "ls", "git status"],
        )
        assert "docker postgres command" in prompt
        assert "docker run postgres" in prompt
        assert "JSON array" in prompt
