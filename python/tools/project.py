"""MCP tools for Vivado project management.

Wrap calls to the TCL plugin and format results in a way that is easy for
an LLM to read. Use `config.timeout_for(<command>)` to select the timeout.
"""

from __future__ import annotations

import json
from typing import Any, Dict

import config


def register(mcp, client_factory) -> None:
    """Register project tools in the MCP instance."""

    @mcp.tool()
    async def open_project(path: str, read_only: bool = False) -> str:
        """Open a Vivado project (.xpr).

        Args:
            path: absolute or relative path to the .xpr file.
            read_only: if True, open the project in read-only mode.

        Returns:
            JSON with project information: name, part, top, runs.
        """
        client = await client_factory()
        data = await client.send_command(
            "open_project",
            {"path": path, "read_only": read_only},
            timeout=config.timeout_for("open_project"),
        )
        return json.dumps(data, indent=2, ensure_ascii=False)

    @mcp.tool()
    async def close_project() -> str:
        """Close the currently open Vivado project."""
        client = await client_factory()
        data = await client.send_command(
            "close_project",
            {},
            timeout=config.timeout_for("close_project"),
        )
        return json.dumps(data, ensure_ascii=False)

    @mcp.tool()
    async def get_project_info() -> str:
        """Return information about the open project: name, part, top module, available runs.

        Useful as the first command in any session to get oriented.
        """
        client = await client_factory()
        data = await client.send_command(
            "get_project_info",
            {},
            timeout=config.timeout_for("get_project_info"),
        )
        return _format_project_info(data)


def _format_project_info(data: Dict[str, Any]) -> str:
    """Format project info in a human-readable layout."""
    lines = []
    lines.append(f"Project:   {data.get('name', '?')}")
    lines.append(f"Part:      {data.get('part', '?')}")
    lines.append(f"Top:       {data.get('top', '?')}")
    lines.append(f"Directory: {data.get('directory', '?')}")
    lines.append(f"XPR file:  {data.get('xpr_file', '?')}")

    runs = data.get("runs") or []
    if runs:
        lines.append("")
        lines.append("Runs:")
        for r in runs:
            lines.append(
                f"  - {r.get('name', '?')}: {r.get('status', '?')} "
                f"(progress={r.get('progress', 0)}%)"
            )
    else:
        lines.append("")
        lines.append("Runs: (none)")
    return "\n".join(lines)
