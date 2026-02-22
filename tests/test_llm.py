"""Tests for the LLM client."""

from __future__ import annotations

import time

from ghst.llm import CircuitState, ConnectionHealth, ResponseCache


class TestConnectionHealth:
    def test_initial_state(self) -> None:
        health = ConnectionHealth()
        assert health.circuit_state == CircuitState.CLOSED
        assert health.consecutive_failures == 0
        assert health.should_allow_request()

    def test_success_resets_failures(self) -> None:
        health = ConnectionHealth()
        health.record_failure()
        health.record_failure()
        assert health.consecutive_failures == 2
        health.record_success(100.0)
        assert health.consecutive_failures == 0

    def test_circuit_opens_after_threshold(self) -> None:
        health = ConnectionHealth()
        for _ in range(3):
            health.record_failure()
        assert health.circuit_state == CircuitState.OPEN
        assert not health.should_allow_request()

    def test_circuit_half_open_after_cooldown(self) -> None:
        health = ConnectionHealth()
        health.COOLDOWN_SECONDS = 0.01  # Very short for testing
        for _ in range(3):
            health.record_failure()
        assert health.circuit_state == CircuitState.OPEN
        time.sleep(0.02)
        assert health.should_allow_request()  # Should transition to HALF_OPEN
        assert health.circuit_state == CircuitState.HALF_OPEN

    def test_circuit_closes_on_probe_success(self) -> None:
        health = ConnectionHealth()
        health.COOLDOWN_SECONDS = 0.01
        for _ in range(3):
            health.record_failure()
        time.sleep(0.02)
        health.should_allow_request()  # Transition to HALF_OPEN
        health.record_success(100.0)
        assert health.circuit_state == CircuitState.CLOSED

    def test_avg_latency(self) -> None:
        health = ConnectionHealth()
        health.record_success(100.0)
        health.record_success(200.0)
        health.record_success(300.0)
        assert health.avg_latency_ms == 200.0

    def test_high_latency(self) -> None:
        health = ConnectionHealth()
        for _ in range(3):
            health.record_success(3000.0)
        assert health.is_high_latency

    def test_status_display(self) -> None:
        health = ConnectionHealth()
        status = health.status_display()
        assert status["state"] == "closed"
        assert "consecutive_failures" in status


class TestResponseCache:
    def test_set_and_get(self) -> None:
        cache = ResponseCache(ttl=10.0)
        cache.set("result", "key1", "key2")
        assert cache.get("key1", "key2") == "result"

    def test_miss(self) -> None:
        cache = ResponseCache(ttl=10.0)
        assert cache.get("nonexistent") is None

    def test_ttl_expiry(self) -> None:
        cache = ResponseCache(ttl=0.01)
        cache.set("result", "key1")
        time.sleep(0.02)
        assert cache.get("key1") is None

    def test_different_keys(self) -> None:
        cache = ResponseCache(ttl=10.0)
        cache.set("result1", "a")
        cache.set("result2", "b")
        assert cache.get("a") == "result1"
        assert cache.get("b") == "result2"
