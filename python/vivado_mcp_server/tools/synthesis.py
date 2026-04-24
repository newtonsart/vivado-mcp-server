"""MCP tools for synthesis.

`run_synthesis` is asynchronous on the TCL server side: it emits an ack,
then progress events, and finally a result. From the LLM's perspective it is
a blocking call to a coroutine — the Python client aggregates progress events
and reports them via `ctx.report_progress` when available.
"""

from __future__ import annotations

import json
from typing import Any, Dict, Optional

from .. import config


def register(mcp, client_factory) -> None:
    @mcp.tool()
    async def run_synthesis(
        jobs: int = 4,
        run: str = "synth_1",
        strategy: Optional[str] = None,
        reset: bool = False,
        ctx=None,
    ) -> str:
        """Launch Vivado synthesis and wait for it to complete.

        Emits progress events during execution. Returns JSON with the final
        state (Complete/Failed), progress, and WNS/TNS if available.

        Args:
            jobs: number of parallel jobs (-jobs N).
            run: synthesis run name (default "synth_1").
            strategy: synthesis strategy name (optional).
            reset: if True, reset the run before launching.
        """
        client = await client_factory()

        async def on_progress(percent: int, message: str) -> None:
            if ctx is not None:
                try:
                    await ctx.report_progress(percent, 100, message)
                except Exception:  # noqa: BLE001
                    # Older MCP SDK versions may have different signatures.
                    pass

        params: Dict[str, Any] = {"jobs": jobs, "run": run, "reset": reset}
        if strategy:
            params["strategy"] = strategy

        data = await client.send_command(
            "run_synthesis",
            params,
            progress_cb=on_progress,
            timeout=config.timeout_for("run_synthesis"),
        )
        return _format_run_result("Synthesis", data)

    @mcp.tool()
    async def get_run_status(run: str = "synth_1") -> str:
        """Return the current status (without waiting) of a run.

        Args:
            run: run name (synth_1, impl_1, ...).
        """
        client = await client_factory()
        data = await client.send_command(
            "get_run_status",
            {"run": run},
            timeout=config.timeout_for("get_run_status"),
        )
        return (
            f"Run: {data.get('run', '?')}\n"
            f"Status: {data.get('status', '?')}\n"
            f"Progress: {data.get('progress', 0)}%"
        )

    @mcp.tool()
    async def reset_run(run: str = "synth_1") -> str:
        """Reset a run so it can be re-launched from scratch."""
        client = await client_factory()
        data = await client.send_command(
            "reset_run",
            {"run": run},
            timeout=config.timeout_for("reset_run"),
        )
        return json.dumps(data, ensure_ascii=False)


def _format_run_result(kind: str, data: Dict[str, Any]) -> str:
    lines = [f"{kind} complete."]
    lines.append(f"  Run:      {data.get('run', '?')}")
    lines.append(f"  Status:   {data.get('status', '?')}")
    lines.append(f"  Progress: {data.get('progress', 0)}%")
    wns = data.get("wns")
    tns = data.get("tns")
    whs = data.get("whs")
    ths = data.get("ths")
    if any(v not in (None, "") for v in (wns, tns, whs, ths)):
        lines.append("  Timing:")
        if wns not in (None, ""): lines.append(f"    WNS: {wns} ns")
        if tns not in (None, ""): lines.append(f"    TNS: {tns} ns")
        if whs not in (None, ""): lines.append(f"    WHS: {whs} ns")
        if ths not in (None, ""): lines.append(f"    THS: {ths} ns")
    return "\n".join(lines)
