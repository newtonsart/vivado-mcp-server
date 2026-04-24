"""MCP tools for timing constraints.

All setters modify the in-memory design. Call write_xdc afterwards to
persist constraints to an .xdc file.
"""

from __future__ import annotations

import json
from typing import Any, Dict, List, Optional

from .. import config


def register(mcp, client_factory) -> None:
    @mcp.tool()
    async def create_clock(
        port: str,
        period: float,
        name: str = "",
        waveform: str = "",
    ) -> str:
        """Create a primary clock on a port or pin.

        Args:
            port: port or pin name (e.g. "sys_clk_p").
            period: clock period in ns (e.g. 10.0 for 100 MHz).
            name: optional clock name. Defaults to the port name.
            waveform: optional waveform as "0 5" (rising/falling edges in ns).
        """
        params: Dict[str, Any] = {"port": port, "period": period}
        if name:
            params["name"] = name
        if waveform:
            params["waveform"] = waveform.split()
        client = await client_factory()
        data = await client.send_command(
            "create_clock", params,
            timeout=config.timeout_for("create_clock"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def create_generated_clock(
        source: str,
        target: str,
        divide_by: int = 0,
        multiply_by: int = 0,
        name: str = "",
    ) -> str:
        """Create a generated clock derived from an existing master clock."""
        params: Dict[str, Any] = {"source": source, "target": target}
        if divide_by > 0:
            params["divide_by"] = divide_by
        if multiply_by > 0:
            params["multiply_by"] = multiply_by
        if name:
            params["name"] = name
        client = await client_factory()
        data = await client.send_command(
            "create_generated_clock", params,
            timeout=config.timeout_for("create_generated_clock"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def set_input_delay(
        clock: str,
        port: str,
        delay: float,
        kind: str = "max",
        add: bool = False,
    ) -> str:
        """Set_input_delay on a port relative to a clock.

        Args:
            clock: clock name (must exist).
            port: input port name.
            delay: delay value in ns.
            kind: "min", "max", or "both".
            add: if True, use -add_delay (accumulate).
        """
        client = await client_factory()
        data = await client.send_command(
            "set_input_delay",
            {"clock": clock, "port": port, "delay": delay, "kind": kind, "add": add},
            timeout=config.timeout_for("set_input_delay"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def set_output_delay(
        clock: str,
        port: str,
        delay: float,
        kind: str = "max",
        add: bool = False,
    ) -> str:
        """Set_output_delay on a port relative to a clock."""
        client = await client_factory()
        data = await client.send_command(
            "set_output_delay",
            {"clock": clock, "port": port, "delay": delay, "kind": kind, "add": add},
            timeout=config.timeout_for("set_output_delay"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def set_false_path(
        from_: str = "",
        to: str = "",
        through: str = "",
    ) -> str:
        """Declare a false path (timing ignored).

        At least one of from_/to/through is required. Each accepts a TCL
        object spec (e.g. "[get_clocks clk_a]" or "[get_pins u1/q]").
        """
        params: Dict[str, Any] = {}
        if from_:
            params["from"] = from_
        if to:
            params["to"] = to
        if through:
            params["through"] = through
        client = await client_factory()
        data = await client.send_command(
            "set_false_path", params,
            timeout=config.timeout_for("set_false_path"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def set_multicycle_path(
        cycles: int,
        from_: str = "",
        to: str = "",
        through: str = "",
        kind: str = "setup",
        start: bool = False,
        end: bool = False,
    ) -> str:
        """Relax a path by N clock cycles.

        Args:
            cycles: number of cycles (N ≥ 2).
            from_/to/through: path spec (at least one required).
            kind: "setup" or "hold".
            start: reference source clock.
            end: reference destination clock.
        """
        params: Dict[str, Any] = {
            "cycles": cycles,
            "kind": kind,
            "start": start,
            "end": end,
        }
        if from_:
            params["from"] = from_
        if to:
            params["to"] = to
        if through:
            params["through"] = through
        client = await client_factory()
        data = await client.send_command(
            "set_multicycle_path", params,
            timeout=config.timeout_for("set_multicycle_path"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def set_clock_groups(
        groups: List[List[str]],
        mode: str = "asynchronous",
        name: str = "",
    ) -> str:
        """Declare groups of clocks unrelated to each other.

        Args:
            groups: list of clock lists, e.g. [["clk_a"], ["clk_b", "clk_c"]].
            mode: "asynchronous" (async CDC) or "exclusive" (never active together).
            name: optional constraint name.
        """
        client = await client_factory()
        data = await client.send_command(
            "set_clock_groups",
            {"groups": groups, "mode": mode, "name": name},
            timeout=config.timeout_for("set_clock_groups"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def report_exceptions(path: str = "") -> str:
        """Report timing exceptions (false/multicycle/groups) currently applied.

        Args:
            path: optional absolute file path; write full report instead of inline.
        """
        client = await client_factory()
        data = await client.send_command(
            "report_exceptions",
            {"path": path},
            timeout=config.timeout_for("report_exceptions"),
        )
        if "path" in data:
            size = data.get("size_bytes", 0)
            return (
                f"exceptions report written to {data['path']} ({size} bytes).\n"
                f"--- head ---\n{data.get('head', '')}"
            )
        return data.get("report", "(empty exceptions report)")
