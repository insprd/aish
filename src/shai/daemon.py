"""shai daemon — asyncio socket server.

Listens on a Unix domain socket, routes JSON requests to the appropriate
handler (autocomplete, NL command, error correction, history search),
and returns responses.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import re
import signal
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from shai.config import AishConfig
from shai.context import ContextInfo
from shai.llm import TIMEOUT_AUTOCOMPLETE, TIMEOUT_HISTORY, TIMEOUT_NL, LLMClient
from shai.prompts import (
    autocomplete_system,
    autocomplete_user,
    error_correction_user,
    history_search_user,
    nl_command_user,
    proactive_system,
    proactive_user,
)
from shai.safety import check_dangerous, sanitize_history, sanitize_output

logger = logging.getLogger("shai")

RATE_LIMIT_RPM = 60  # max requests per minute to LLM


class RateLimiter:
    """Simple RPM-based rate limiter."""

    def __init__(self, rpm: int = RATE_LIMIT_RPM) -> None:
        self.rpm = rpm
        self._timestamps: deque[float] = deque()

    def allow(self) -> bool:
        now = time.monotonic()
        while self._timestamps and now - self._timestamps[0] > 60:
            self._timestamps.popleft()
        if len(self._timestamps) >= self.rpm:
            return False
        self._timestamps.append(now)
        return True


@dataclass
class SessionEntry:
    """One entry in the rolling session buffer."""

    command: str
    output: str  # truncated to SESSION_OUTPUT_LINES


@dataclass
class SessionBuffer:
    """Rolling buffer of recent commands and their outputs.

    Used for proactive suggestions to give the LLM session-level awareness.
    """

    MAX_ENTRIES: int = 20
    MAX_OUTPUT_LINES: int = 20
    entries: deque[SessionEntry] = field(default_factory=lambda: deque(maxlen=20))

    def add(self, command: str, output: str) -> None:
        # Truncate output to last MAX_OUTPUT_LINES lines
        lines = output.splitlines()
        if len(lines) > self.MAX_OUTPUT_LINES:
            lines = lines[-self.MAX_OUTPUT_LINES:]
        self.entries.append(SessionEntry(command=command, output="\n".join(lines)))

    def format_for_prompt(self) -> str:
        if not self.entries:
            return ""
        parts = []
        for i, entry in enumerate(self.entries):
            idx = len(self.entries) - i
            parts.append(f"[{idx}] {entry.command}")
            if entry.output.strip():
                # Indent output
                indented = "\n".join(f"    {line}" for line in entry.output.splitlines())
                parts.append(indented)
        return "\n".join(parts)


def _ensure_leading_space(buffer: str, suggestion: str) -> str:
    """Ensure the suggestion has a leading space if needed.

    Prevents LLM completions from merging into the buffer
    (e.g. 'ffmpeg' + '-i' → 'ffmpeg -i' not 'ffmpeg-i').
    """
    if not suggestion or not buffer:
        return suggestion
    if (
        not buffer[-1].isspace()
        and not suggestion[0].isspace()
        and suggestion[0] in "-|>&;<()"
    ):
        return " " + suggestion
    return suggestion


_FENCE_RE: re.Pattern[str] | None = None


def _strip_code_fences(text: str) -> str:
    """Remove markdown code fences that LLMs sometimes wrap responses in."""
    global _FENCE_RE
    if _FENCE_RE is None:
        _FENCE_RE = re.compile(r"^```(?:\w*)\n?(.*?)```$", re.DOTALL)
    m = _FENCE_RE.match(text.strip())
    return m.group(1).strip() if m else text


class AishDaemon:
    """Main daemon process."""

    IDLE_TIMEOUT_SECONDS: float = 30 * 60  # 30 minutes

    def __init__(self, config: AishConfig | None = None) -> None:
        self.config = config or AishConfig.load()
        self.llm = LLMClient(self.config)
        self.context = ContextInfo()
        self.session = SessionBuffer()
        self._server: asyncio.AbstractServer | None = None
        self._last_activity: float = 0.0
        self._rate_limiter = RateLimiter()

    async def handle_request(self, data: dict[str, Any]) -> dict[str, Any]:
        """Route a request to the appropriate handler."""
        self._last_activity = asyncio.get_event_loop().time()
        req_type = data.get("type", "")
        try:
            if req_type == "complete":
                return await self._handle_complete(data)
            elif req_type == "nl":
                return await self._handle_nl(data)
            elif req_type == "error_correct":
                return await self._handle_error_correct(data)
            elif req_type == "history_search":
                return await self._handle_history_search(data)
            elif req_type == "reload_config":
                return self._handle_reload_config()
            else:
                return {"type": "error", "message": f"Unknown request type: {req_type}"}
        except Exception as e:
            logger.exception("Error handling %s request", req_type)
            return {"type": "error", "message": str(e)}

    async def _handle_complete(self, data: dict[str, Any]) -> dict[str, Any]:
        """Handle autocomplete and proactive suggestion requests."""
        buffer = data.get("buffer", "")
        cwd = data.get("cwd", os.getcwd())
        shell = data.get("shell", "zsh")
        history = sanitize_history(data.get("history", []))
        last_command = data.get("last_command", "")
        last_output = data.get("last_output", "")
        request_id = data.get("request_id", "")

        # Rate limit check
        if not self._rate_limiter.allow():
            logger.debug("Rate limit exceeded — dropping request")
            return {"type": "complete", "request_id": request_id, "suggestion": ""}

        is_proactive = not buffer and last_output

        if is_proactive:
            # Add to session buffer
            sanitized_output = sanitize_output(last_output)
            self.session.add(last_command, sanitized_output)

            # Skip proactive on high latency
            if self.llm.health.is_high_latency:
                return {"type": "complete", "request_id": request_id, "suggestion": ""}

            session_text = self.session.format_for_prompt()
            messages = [
                {"role": "system", "content": proactive_system(session_text)},
                {"role": "user", "content": proactive_user(
                    cwd=cwd, history=history, last_command=last_command,
                    last_output=sanitized_output, shell=shell,
                )},
            ]
            cache_key = ("proactive", last_command, cwd, str(hash(last_output)))
            model = self.config.provider.effective_autocomplete_model
            suggestion = await self.llm.complete(
                messages, model=model, timeout=TIMEOUT_AUTOCOMPLETE,
                use_cache_key=cache_key,
            )
        else:
            # Regular autocomplete
            exit_status = data.get("exit_status", 0)
            messages = [
                {"role": "system", "content": autocomplete_system()},
                {"role": "user", "content": autocomplete_user(
                    buffer=buffer, cwd=cwd, history=history, shell=shell,
                    exit_status=exit_status,
                )},
            ]
            cache_key = ("autocomplete", buffer, cwd)
            model = self.config.provider.effective_autocomplete_model
            suggestion = await self.llm.complete(
                messages, model=model, timeout=TIMEOUT_AUTOCOMPLETE,
                use_cache_key=cache_key,
            )
            # Post-process: ensure leading space
            suggestion = _ensure_leading_space(buffer, suggestion)

        # Strip trailing whitespace but preserve leading
        suggestion = suggestion.rstrip()

        # Strip markdown code fences
        suggestion = _strip_code_fences(suggestion)
        # Reject multiline suggestions for autocomplete
        if "\n" in suggestion:
            suggestion = suggestion.split("\n")[0].rstrip()

        # Safety check
        full_command = buffer + suggestion if buffer else suggestion
        warning = check_dangerous(full_command)

        response: dict[str, Any] = {
            "type": "complete",
            "request_id": request_id,
            "suggestion": suggestion,
        }
        if warning:
            response["warning"] = warning

        return response

    async def _handle_nl(self, data: dict[str, Any]) -> dict[str, Any]:
        """Handle natural language command construction."""
        prompt = data.get("prompt", "")
        cwd = data.get("cwd", os.getcwd())
        shell = data.get("shell", "zsh")
        buffer = data.get("buffer", "")
        history = sanitize_history(data.get("history", []))

        if not prompt:
            return {"type": "nl", "command": ""}

        messages = [
            {"role": "system", "content": autocomplete_system()},
            {"role": "user", "content": nl_command_user(
                prompt=prompt, cwd=cwd, buffer=buffer,
                history=history, shell=shell,
            )},
        ]
        model = self.config.provider.model
        command = await self.llm.complete_with_retry(
            messages, model=model, timeout=TIMEOUT_NL, retries=1,
        )

        response: dict[str, Any] = {"type": "nl", "command": command}

        if command:
            warning = check_dangerous(command)
            if warning:
                response["warning"] = warning

        return response

    async def _handle_error_correct(self, data: dict[str, Any]) -> dict[str, Any]:
        """Handle error correction requests."""
        failed_command = data.get("failed_command", "")
        exit_status = data.get("exit_status", 1)
        stderr = sanitize_output(data.get("stderr", ""))
        cwd = data.get("cwd", os.getcwd())
        shell = data.get("shell", "zsh")

        if not failed_command:
            return {"type": "error_correct", "suggestion": ""}

        messages = [
            {"role": "system", "content": autocomplete_system()},
            {"role": "user", "content": error_correction_user(
                failed_command=failed_command, exit_status=exit_status,
                stderr=stderr, cwd=cwd, shell=shell,
            )},
        ]
        model = self.config.provider.effective_autocomplete_model
        suggestion = await self.llm.complete(
            messages, model=model, timeout=TIMEOUT_AUTOCOMPLETE,
        )

        return {"type": "error_correct", "suggestion": suggestion.rstrip()}

    async def _handle_history_search(self, data: dict[str, Any]) -> dict[str, Any]:
        """Handle natural language history search."""
        query = data.get("query", "")
        history = sanitize_history(data.get("history", []))
        shell = data.get("shell", "zsh")

        if not query or not history:
            return {"type": "history_search", "results": []}

        messages = [
            {"role": "system", "content": autocomplete_system()},
            {"role": "user", "content": history_search_user(
                query=query, history=history, shell=shell,
            )},
        ]
        model = self.config.provider.model
        response_text = await self.llm.complete_with_retry(
            messages, model=model, timeout=TIMEOUT_HISTORY, retries=1,
        )

        # Parse JSON results
        try:
            results = json.loads(response_text)
            if not isinstance(results, list):
                results = []
        except (json.JSONDecodeError, TypeError):
            results = []

        return {"type": "history_search", "results": results}

    def _handle_reload_config(self) -> dict[str, Any]:
        """Reload configuration from disk."""
        try:
            self.config = AishConfig.load()
            self.llm.config = self.config
            logger.info("Configuration reloaded")
            return {"type": "reload_config", "ok": True}
        except Exception as e:
            logger.error("Failed to reload config: %s", e)
            return {"type": "reload_config", "ok": False, "message": str(e)}

    async def _handle_connection(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        """Handle a single client connection."""
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                try:
                    data = json.loads(line.decode())
                except json.JSONDecodeError:
                    logger.warning("Invalid JSON received")
                    continue

                response = await self.handle_request(data)
                logger.debug("Request: %s → %s", data.get("type"), response)
                writer.write(json.dumps(response).encode() + b"\n")
                await writer.drain()
        except (ConnectionResetError, BrokenPipeError):
            pass
        finally:
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()

    async def start(self) -> None:
        """Start the daemon socket server."""
        socket_path = self.config.get_socket_path()
        pid_path = self.config.get_pid_path()

        # Clean up stale socket
        if socket_path.exists():
            socket_path.unlink()

        self._server = await asyncio.start_unix_server(
            self._handle_connection, path=str(socket_path)
        )

        # Set socket permissions (owner only)
        os.chmod(str(socket_path), 0o600)

        # Write PID file
        pid_path.write_text(str(os.getpid()))

        self._last_activity = asyncio.get_event_loop().time()
        logger.info("shai daemon started (pid %d, socket %s)", os.getpid(), socket_path)

        async with self._server:
            while True:
                await asyncio.sleep(60)  # check every minute
                idle = asyncio.get_event_loop().time() - self._last_activity
                if idle >= self.IDLE_TIMEOUT_SECONDS:
                    logger.info("Idle timeout (%.0fs) — shutting down", idle)
                    break
            await self.stop()

    async def stop(self) -> None:
        """Stop the daemon."""
        if self._server:
            self._server.close()
            await self._server.wait_closed()
        await self.llm.close()

        # Clean up
        socket_path = self.config.get_socket_path()
        pid_path = self.config.get_pid_path()
        socket_path.unlink(missing_ok=True)
        pid_path.unlink(missing_ok=True)

        logger.info("shai daemon stopped")


async def _run() -> None:
    """Run the daemon."""
    log_path = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "shai"
    log_path.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.DEBUG,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        handlers=[
            logging.FileHandler(log_path / "daemon.log"),
            logging.StreamHandler(),
        ],
    )
    daemon = AishDaemon()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda: asyncio.create_task(daemon.stop()))

    await daemon.start()


def main() -> None:
    """Entry point for `python -m shai.daemon`."""
    asyncio.run(_run())


if __name__ == "__main__":
    main()
