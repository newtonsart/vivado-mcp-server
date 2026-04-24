"""MCP tools for implementation and bitstream generation."""

from __future__ import annotations

from typing import Any, Dict, Optional

from .. import config
from .synthesis import _format_run_result  # noqa: F401 (reused here)


def register(mcp, client_factory) -> None:
    @mcp.tool()
    async def run_implementation(
        jobs: int = 4,
        run: str = "impl_1",
        strategy: Optional[str] = None,
        reset: bool = False,
        ctx=None,
    ) -> str:
        """Launch Vivado implementation (place + route) and wait for completion.

        Args:
            jobs: number of parallel jobs.
            run: run name (default impl_1).
            strategy: implementation strategy name.
            reset: reset the run before launching.
        """
        client = await client_factory()

        async def on_progress(percent: int, message: str) -> None:
            if ctx is not None:
                try:
                    await ctx.report_progress(percent, 100, message)
                except Exception:  # noqa: BLE001
                    pass

        params: Dict[str, Any] = {"jobs": jobs, "run": run, "reset": reset}
        if strategy:
            params["strategy"] = strategy

        data = await client.send_command(
            "run_implementation",
            params,
            progress_cb=on_progress,
            timeout=config.timeout_for("run_implementation"),
        )
        return _format_run_result("Implementation", data)

    @mcp.tool()
    async def generate_bitstream(
        jobs: int = 4,
        run: str = "impl_1",
        reset: bool = False,
        ctx=None,
    ) -> str:
        """Generate the bitstream (write_bitstream) and wait for completion.

        On success, returns the path to the .bit file if it could be located.
        """
        client = await client_factory()

        async def on_progress(percent: int, message: str) -> None:
            if ctx is not None:
                try:
                    await ctx.report_progress(percent, 100, message)
                except Exception:  # noqa: BLE001
                    pass

        data = await client.send_command(
            "generate_bitstream",
            {"jobs": jobs, "run": run, "reset": reset},
            progress_cb=on_progress,
            timeout=config.timeout_for("generate_bitstream"),
        )
        lines = [_format_run_result("Bitstream", data)]
        bitpath = data.get("bitstream_path")
        if bitpath:
            lines.append(f"  Bitstream: {bitpath}")
        return "\n".join(lines)
