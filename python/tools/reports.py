"""MCP tools for reports: timing, utilization, messages, DRC."""

from __future__ import annotations

import json
from typing import Any, Dict

import config


def register(mcp, client_factory) -> None:
    @mcp.tool()
    async def get_timing_summary(run: str = "impl_1", max_paths: int = 10) -> str:
        """Return the timing summary for the given run.

        Includes WNS, TNS, WHS, THS extracted from the report.
        """
        client = await client_factory()
        data = await client.send_command(
            "get_timing_summary",
            {"run": run, "max_paths": max_paths},
            timeout=config.timeout_for("get_timing_summary"),
        )
        return _format_timing_summary(data)

    @mcp.tool()
    async def get_timing_paths(max_paths: int = 10, delay_type: str = "max") -> str:
        """Return the critical paths (worst paths) of the open design.

        Args:
            max_paths: how many paths to return.
            delay_type: "max", "min", or "min_max".
        """
        client = await client_factory()
        data = await client.send_command(
            "get_timing_paths",
            {"max_paths": max_paths, "delay_type": delay_type},
            timeout=config.timeout_for("get_timing_paths"),
        )
        paths = data.get("paths") or []
        if not paths:
            return "(no critical paths found)"
        lines = [f"{len(paths)} critical paths (delay_type={delay_type}):"]
        for i, p in enumerate(paths, 1):
            lines.append(
                f"  {i}. slack={p.get('slack', '?')} "
                f"from={p.get('from', '?')} to={p.get('to', '?')} "
                f"group={p.get('group', '?')}"
            )
        return "\n".join(lines)

    @mcp.tool()
    async def get_utilization() -> str:
        """Return a utilization summary (LUTs, FFs, BRAM, DSP, IO, clocks)."""
        client = await client_factory()
        data = await client.send_command(
            "get_utilization",
            {},
            timeout=config.timeout_for("get_utilization"),
        )
        summary = data.get("summary") or []
        if not summary:
            # If we could not parse the table, return the full text report.
            return data.get("report", "(empty report)")
        lines = ["Resource utilization:"]
        for row in summary:
            avail = row.get("available")
            pct = row.get("percent")
            if avail:
                lines.append(
                    f"  - {row.get('name', '?'):30s} "
                    f"{row.get('used', 0):>8} / {avail:>8} ({pct}%)"
                )
            else:
                lines.append(
                    f"  - {row.get('name', '?'):30s} "
                    f"{row.get('used', 0):>8} (used; run report_utilization for %)"
                )
        return "\n".join(lines)

    @mcp.tool()
    async def get_messages(severity: str = "ERROR", limit: int = 100) -> str:
        """Retrieve Vivado messages filtered by severity.

        Args:
            severity: "ERROR", "CRITICAL WARNING", "WARNING", or "INFO".
            limit: maximum number of messages to return.
        """
        client = await client_factory()
        data = await client.send_command(
            "get_messages",
            {"severity": severity, "limit": limit},
            timeout=config.timeout_for("get_messages"),
        )
        msgs = data.get("messages") or []
        total = data.get("count", 0)
        if not msgs:
            return f"No {severity} messages (total count: {total})."
        lines = [f"{len(msgs)} of {total} {severity} messages:"]
        for m in msgs:
            lines.append(f"  - {m}")
        return "\n".join(lines)

    @mcp.tool()
    async def get_drc() -> str:
        """Run report_drc on the open design and return the report."""
        client = await client_factory()
        data = await client.send_command(
            "get_drc",
            {},
            timeout=config.timeout_for("get_drc"),
        )
        return data.get("report", "(empty DRC report)")


def _format_timing_summary(data: Dict[str, Any]) -> str:
    wns = data.get("wns", "")
    tns = data.get("tns", "")
    whs = data.get("whs", "")
    ths = data.get("ths", "")
    lines = [f"Timing summary for {data.get('run', '?')}:"]
    lines.append(f"  WNS: {wns} ns")
    lines.append(f"  TNS: {tns} ns")
    lines.append(f"  WHS: {whs} ns")
    lines.append(f"  THS: {ths} ns")
    verdict = _timing_verdict(wns, whs)
    if verdict:
        lines.append(f"  Verdict: {verdict}")
    return "\n".join(lines)


def _timing_verdict(wns: Any, whs: Any) -> str:
    try:
        wns_f = float(wns) if wns not in ("", None) else None
        whs_f = float(whs) if whs not in ("", None) else None
    except (TypeError, ValueError):
        return ""
    if wns_f is None or whs_f is None:
        return ""
    if wns_f >= 0 and whs_f >= 0:
        return "TIMING MET"
    return "TIMING VIOLATED"
