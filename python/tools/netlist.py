"""MCP tools for netlist queries: cells, nets, ports, clocks, hierarchy."""

from __future__ import annotations

import json
from typing import Any, Dict

import config


def register(mcp, client_factory) -> None:
    @mcp.tool()
    async def get_cells(
        pattern: str = "*",
        hierarchical: bool = False,
        limit: int = 200,
    ) -> str:
        """List cells in the design matching a glob pattern.

        Args:
            pattern: glob pattern (e.g. "*", "cpu/alu/*").
            hierarchical: if True, search recursively through the hierarchy.
            limit: maximum number of results.
        """
        client = await client_factory()
        data = await client.send_command(
            "get_cells",
            {"pattern": pattern, "hierarchical": hierarchical, "limit": limit},
            timeout=config.timeout_for("get_cells"),
        )
        cells = data.get("cells") or []
        total = data.get("total", len(cells))
        if not cells:
            return f"No cells matched '{pattern}'."
        lines = [f"{len(cells)} of {total} cells matching '{pattern}':"]
        for c in cells:
            lines.append(f"  - {c.get('name', '?')}  (ref={c.get('ref', '?')})")
        return "\n".join(lines)

    @mcp.tool()
    async def get_nets(
        pattern: str = "*",
        hierarchical: bool = False,
        limit: int = 200,
    ) -> str:
        """List nets matching a pattern."""
        client = await client_factory()
        data = await client.send_command(
            "get_nets",
            {"pattern": pattern, "hierarchical": hierarchical, "limit": limit},
            timeout=config.timeout_for("get_nets"),
        )
        nets = data.get("nets") or []
        total = data.get("total", len(nets))
        if not nets:
            return f"No nets matched '{pattern}'."
        lines = [f"{len(nets)} of {total} nets matching '{pattern}':"]
        for n in nets:
            lines.append(f"  - {n.get('name', '?')}  (type={n.get('type', '?')})")
        return "\n".join(lines)

    @mcp.tool()
    async def get_ports(pattern: str = "*") -> str:
        """List top-level ports matching the pattern.

        Returns direction, package pin, and iostandard.
        """
        client = await client_factory()
        data = await client.send_command(
            "get_ports",
            {"pattern": pattern},
            timeout=config.timeout_for("get_ports"),
        )
        ports = data.get("ports") or []
        if not ports:
            return f"No ports matched '{pattern}'."
        lines = [f"{len(ports)} ports matching '{pattern}':"]
        for p in ports:
            lines.append(
                f"  - {p.get('name', '?'):20s} dir={p.get('direction', '?'):3s} "
                f"pin={p.get('package_pin', '?'):6s} iostd={p.get('iostandard', '?')}"
            )
        return "\n".join(lines)

    @mcp.tool()
    async def get_clocks() -> str:
        """List clocks defined in the design.

        Returns name, period (ns), source, and waveform.
        """
        client = await client_factory()
        data = await client.send_command(
            "get_clocks",
            {},
            timeout=config.timeout_for("get_clocks"),
        )
        clocks = data.get("clocks") or []
        if not clocks:
            return "No clocks defined."
        lines = [f"{len(clocks)} clocks:"]
        for c in clocks:
            lines.append(
                f"  - {c.get('name', '?'):20s} period={c.get('period', '?')}ns "
                f"source={c.get('source', '?')}"
            )
        return "\n".join(lines)

    @mcp.tool()
    async def get_design_hierarchy(max_depth: int = 5) -> str:
        """Return the module hierarchy of the design (up to `max_depth` levels)."""
        client = await client_factory()
        data = await client.send_command(
            "get_design_hierarchy",
            {"max_depth": max_depth},
            timeout=config.timeout_for("get_design_hierarchy"),
        )
        nodes = data.get("nodes") or []
        if not nodes:
            return "(empty hierarchy)"
        top = data.get("top", "?")
        lines = [f"Top: {top}  (max_depth={max_depth}, nodes={len(nodes)})"]
        for node in nodes:
            depth = node.get("depth", 1)
            indent = "  " * depth
            lines.append(
                f"{indent}- {node.get('name', '?')} "
                f"({node.get('ref', '?')})"
            )
        return "\n".join(lines)
