"""MCP tools for run management and timing-closure helpers."""

from __future__ import annotations

import json
from typing import Any, Dict

import config


def register(mcp, client_factory) -> None:
    @mcp.tool()
    async def list_strategies(flow: str = "impl") -> str:
        """List synthesis or implementation strategies available in the project.

        Args:
            flow: "synth" or "impl".
        """
        client = await client_factory()
        data = await client.send_command(
            "list_strategies",
            {"flow": flow},
            timeout=config.timeout_for("list_strategies"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def set_run_strategy(run: str, strategy: str, reset: bool = True) -> str:
        """Set the strategy on a run (optionally resetting first).

        Args:
            run: run name (e.g. "impl_1", "synth_1").
            strategy: strategy name (see list_strategies).
            reset: reset the run before setting (default True).
        """
        client = await client_factory()
        data = await client.send_command(
            "set_run_strategy",
            {"run": run, "strategy": strategy, "reset": reset},
            timeout=config.timeout_for("set_run_strategy"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def get_run_stats(run: str = "impl_1") -> str:
        """Return status + strategy + WNS/TNS/WHS/THS + elapsed for a run."""
        client = await client_factory()
        data = await client.send_command(
            "get_run_stats",
            {"run": run},
            timeout=config.timeout_for("get_run_stats"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def wait_on_run(run: str = "impl_1", timeout: int = 3600) -> str:
        """Block until the run completes or the timeout expires.

        Args:
            run: run name.
            timeout: seconds to wait (default 1 h).
        """
        client = await client_factory()
        cmd_timeout = max(float(timeout) + 30.0, config.timeout_for("wait_on_run"))
        data = await client.send_command(
            "wait_on_run",
            {"run": run, "timeout": timeout},
            timeout=cmd_timeout,
        )
        return json.dumps(data, indent=2, ensure_ascii=False)
