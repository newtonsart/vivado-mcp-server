"""Entry point for the `vivado-mcp-server` MCP server.

Typical usage:
    python -m vivado_mcp_server                          # stdio MCP
    vivado-mcp-server                                    # console script
    python -m vivado_mcp_server --host 127.0.0.1 --port 7654

Supported environment variables (see config.py): VMCP_HOST, VMCP_PORT,
VMCP_LOGLEVEL, VMCP_RECONNECT_MAX, VMCP_RECONNECT_ATTEMPTS.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
import time
from collections import deque
from typing import Any, Deque, Dict, Optional

from . import config
from . import tools as tools_pkg
from .vivado.client import VivadoClient
from .vivado.exceptions import VivadoError

# -----------------------------------------------------------------------------
# Official Anthropic MCP SDK dependency. Install with `pip install mcp`.
# We try the FastMCP API (recent) and provide a friendly error if not available.
# -----------------------------------------------------------------------------
try:
    from mcp.server.fastmcp import FastMCP
except ImportError as _exc:  # noqa: F841
    print(
        "ERROR: The Anthropic MCP SDK is not installed.\n"
        "       Install it with: pip install 'mcp>=1.0' anyio\n",
        file=sys.stderr,
    )
    raise

log = logging.getLogger("vivado-mcp-server.server")

# -----------------------------------------------------------------------------
# Global state: a single VivadoClient shared by all tools.
# Lazily initialized — we don't want to block MCP startup if Vivado is not
# yet running.
# -----------------------------------------------------------------------------
_client: Optional[VivadoClient] = None
_client_lock = asyncio.Lock()

# Server-initiated notifications (run_complete, run_failed, bitstream_complete,
# ...) arrive asynchronously on the TCP connection. We buffer them in a
# bounded deque so an LLM can poll `get_recent_events` after dispatching a
# long-running command or reconnecting.
_event_buffer: Deque[Dict[str, Any]] = deque(maxlen=200)


def _on_notification(event: str, data: Dict[str, Any]) -> None:
    _event_buffer.append(
        {
            "timestamp": time.time(),
            "event": event,
            "data": data,
        }
    )


async def get_client() -> VivadoClient:
    """Return the shared VivadoClient, creating/connecting it if needed."""
    global _client
    async with _client_lock:
        if _client is None:
            _client = VivadoClient(
                host=config.HOST,
                port=config.PORT,
                reconnect_initial_delay=config.RECONNECT_INITIAL_DELAY,
                reconnect_max_delay=config.RECONNECT_MAX_DELAY,
                reconnect_max_attempts=config.RECONNECT_MAX_ATTEMPTS,
            )
            _client.add_notification_handler(_on_notification)
        if not _client.connected:
            try:
                await _client.connect()
            except VivadoError as exc:
                log.error("connect failed: %s", exc)
                raise
    return _client


# -----------------------------------------------------------------------------
# MCP instance
# -----------------------------------------------------------------------------
mcp = FastMCP("vivado")


# -----------------------------------------------------------------------------
# Meta-tools registered directly here (ping, run_tcl, check_connection).
# Domain-specific tools are registered via tools.register_all.
# -----------------------------------------------------------------------------
@mcp.tool()
async def check_connection() -> str:
    """Check whether the TCL plugin is reachable and responds to `ping`.

    Useful as the first command in any session to detect whether Vivado is
    running with the plugin loaded.
    """
    try:
        client = await get_client()
        data = await client.ping()
        return (
            f"Vivado plugin is healthy.\n"
            f"  version: {data.get('vivado_version', '?')}\n"
            f"  timestamp: {data.get('timestamp', '?')}"
        )
    except VivadoError as exc:
        return f"Vivado plugin NOT reachable: {exc}"


@mcp.tool()
async def run_tcl(expr: str) -> str:
    """Execute an arbitrary TCL snippet in the Vivado interpreter.

    ESCAPE HATCH: use only when no dedicated tool exists, or for ad-hoc
    inspection. There is no security filtering: the command runs with the
    full privileges of the Vivado process.

    Args:
        expr: TCL snippet (may span multiple lines).
    """
    client = await get_client()
    data = await client.run_tcl(expr, timeout=config.timeout_for("run_tcl"))
    result = data.get("result", "")
    type_ = data.get("type", "string")
    return f"[{type_}] {result}"


@mcp.tool()
async def get_recent_events(limit: int = 20) -> str:
    """Return recent server-pushed notifications (run_complete, run_failed,
    bitstream_complete, ...).

    The Python client buffers up to 200 notifications as they arrive on the
    TCP connection. Poll this tool after dispatching an async command (e.g.
    `run_synthesis`) or after reconnecting to recover missed events.

    Args:
        limit: maximum number of most-recent events to return (default 20).
    """
    items = list(_event_buffer)
    if limit > 0:
        items = items[-limit:]
    items.reverse()
    if not items:
        return "(no events buffered)"
    return json.dumps(items, indent=2, ensure_ascii=False)


@mcp.tool()
async def reload_plugin(source_dir: str = "") -> str:
    """Hot-reload all TCL handler files in the running Vivado plugin.

    Re-sources handler files and re-registers all commands without restarting
    the server or losing the TCP connection. Use after editing TCL handler code.

    Args:
        source_dir: Optional path to the tcl/ directory to reload from.
                    Defaults to the installed plugin path. Pass the repo path
                    (e.g. "C:/path/to/vivado-mcp-server/tcl") during development.
    """
    client = await get_client()
    params = {}
    if source_dir:
        params["source_dir"] = source_dir
    data = await client.send_command(
        "reload_plugin", params, timeout=config.timeout_for("reload_plugin")
    )
    return (
        f"Reload complete.\n"
        f"  source_dir: {data.get('source_dir', '?')}"
    )


@mcp.tool()
async def restart_server(delay_seconds: float = 1.0) -> str:
    """Exit the Python MCP process so the host (Claude Desktop / Codex)
    re-launches it. Use after editing Python tool code — the plugin TCL
    socket survives because it lives inside Vivado, only the Python side
    is replaced. Host auto-reconnects on the next tool call.

    Args:
        delay_seconds: grace period before exit so this response can flush
                       over stdio (default 1.0).
    """
    async def _exit_later() -> None:
        await asyncio.sleep(max(0.1, float(delay_seconds)))
        log.info("restart_server: exiting for host-side restart")
        # os._exit bypasses pending-coroutine cleanup that would otherwise
        # keep the process alive after FastMCP has half-shut-down.
        import os
        os._exit(0)

    asyncio.create_task(_exit_later())
    return (
        f"Python MCP server will exit in {delay_seconds:.1f}s. "
        f"The next tool call from the host will spawn a fresh process "
        f"with any new/edited tools registered."
    )


# -----------------------------------------------------------------------------
# Register all tools from the `tools/` package.
# -----------------------------------------------------------------------------
tools_pkg.register_all(mcp, get_client)


# -----------------------------------------------------------------------------
# Utilities
# -----------------------------------------------------------------------------
def _setup_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="[%(asctime)s] %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )


def _parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="vivado-mcp-server",
        description="MCP server bridging to a running Vivado instance via TCP.",
    )
    p.add_argument("--host", default=config.HOST, help="TCP host of the plugin (default: %(default)s)")
    p.add_argument("--port", type=int, default=config.PORT, help="TCP port (default: %(default)d)")
    p.add_argument("--log-level", default=config.LOG_LEVEL, help="logging level (default: %(default)s)")
    return p.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> None:
    """Entry point for `python -m server` and the console script."""
    args = _parse_args(argv)
    # Override global config with CLI args.
    config.HOST = args.host
    config.PORT = args.port
    _setup_logging(args.log_level)
    log.info("starting vivado-mcp-server; plugin at %s:%d", config.HOST, config.PORT)
    # FastMCP.run() handles stdio initialization and event loop management.
    mcp.run()


if __name__ == "__main__":
    main()
