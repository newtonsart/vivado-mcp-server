"""Tests for `vivado_mcp_server.config`."""

from __future__ import annotations

from vivado_mcp_server import config


def test_timeout_for_known_command():
    assert config.timeout_for("run_synthesis") == config.COMMAND_TIMEOUTS["run_synthesis"]


def test_timeout_for_unknown_command_falls_back_to_default():
    assert config.timeout_for("no-such-cmd") == config.COMMAND_TIMEOUTS["default"]


def test_all_timeouts_are_positive_numbers():
    for cmd, t in config.COMMAND_TIMEOUTS.items():
        assert isinstance(t, (int, float)), cmd
        assert t > 0, cmd


def test_reconnect_attempts_default_is_finite():
    # Must be finite so tool calls don't hang forever when Vivado is down.
    assert config.RECONNECT_MAX_ATTEMPTS > 0
