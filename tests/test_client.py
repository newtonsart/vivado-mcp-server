"""End-to-end tests for `VivadoClient` against a mock NDJSON TCP server.

The mock server impersonates the TCL plugin: it accepts one request per
connection, optionally emits ack/progress, then a final result.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any, Callable, Dict, List, Optional

import pytest

from vivado_mcp_server.vivado.client import VivadoClient
from vivado_mcp_server.vivado.exceptions import (
    VivadoConnectionError,
    VivadoRemoteError,
    VivadoTimeoutError,
)


# ----------------------------------------------------------------------------
# Mock server helpers
# ----------------------------------------------------------------------------

ResponseBuilder = Callable[[Dict[str, Any]], List[Dict[str, Any]]]


async def _run_mock_server(
    builder: ResponseBuilder,
    *,
    port_holder: Dict[str, int],
    stop_event: asyncio.Event,
) -> None:
    """Accept one or more connections and, for each incoming request line,
    emit the list of response dicts returned by `builder(request)`."""

    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            while True:
                line = await reader.readline()
                if not line:
                    return
                req = json.loads(line.decode("utf-8"))
                for resp in builder(req):
                    # Ensure every response carries the matching request id.
                    resp.setdefault("id", req.get("id"))
                    writer.write((json.dumps(resp) + "\n").encode("utf-8"))
                    await writer.drain()
        except (ConnectionResetError, asyncio.IncompleteReadError):
            pass
        finally:
            writer.close()

    server = await asyncio.start_server(handle, host="127.0.0.1", port=0)
    port_holder["port"] = server.sockets[0].getsockname()[1]
    async with server:
        await stop_event.wait()


async def _make_mock(builder: ResponseBuilder) -> tuple[int, asyncio.Task, asyncio.Event]:
    port_holder: Dict[str, int] = {}
    stop_event = asyncio.Event()
    task = asyncio.create_task(
        _run_mock_server(builder, port_holder=port_holder, stop_event=stop_event)
    )
    # Poll until the port is bound.
    for _ in range(50):
        if "port" in port_holder:
            break
        await asyncio.sleep(0.02)
    assert "port" in port_holder, "mock server failed to bind"
    return port_holder["port"], task, stop_event


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_send_command_returns_ok_data():
    def builder(req: Dict[str, Any]) -> List[Dict[str, Any]]:
        assert req["command"] == "ping"
        return [{"type": "result", "status": "ok", "data": {"pong": True}}]

    port, task, stop = await _make_mock(builder)
    try:
        async with VivadoClient(host="127.0.0.1", port=port, reconnect_max_attempts=1) as vv:
            data = await vv.send_command("ping", {}, timeout=2.0)
        assert data == {"pong": True}
    finally:
        stop.set()
        await task


@pytest.mark.asyncio
async def test_send_command_raises_on_remote_error():
    def builder(req: Dict[str, Any]) -> List[Dict[str, Any]]:
        return [{
            "type": "result",
            "status": "error",
            "error": {"code": "NO_PROJECT", "message": "none open"},
        }]

    port, task, stop = await _make_mock(builder)
    try:
        async with VivadoClient(host="127.0.0.1", port=port, reconnect_max_attempts=1) as vv:
            with pytest.raises(VivadoRemoteError) as exc_info:
                await vv.send_command("get_project_info", {}, timeout=2.0)
        assert exc_info.value.code == "NO_PROJECT"
    finally:
        stop.set()
        await task


@pytest.mark.asyncio
async def test_progress_callback_fires_between_ack_and_result():
    received: List[tuple[int, str]] = []

    def builder(req: Dict[str, Any]) -> List[Dict[str, Any]]:
        return [
            {"type": "ack", "status": "started", "message": "launched"},
            {"type": "progress", "percent": 25, "message": "synth"},
            {"type": "progress", "percent": 75, "message": "synth"},
            {"type": "result", "status": "ok", "data": {"done": True}},
        ]

    async def on_progress(pct: int, msg: str) -> None:
        received.append((pct, msg))

    port, task, stop = await _make_mock(builder)
    try:
        async with VivadoClient(host="127.0.0.1", port=port, reconnect_max_attempts=1) as vv:
            data = await vv.send_command(
                "run_synthesis", {}, progress_cb=on_progress, timeout=2.0
            )
        assert data == {"done": True}
        assert received == [(25, "synth"), (75, "synth")]
    finally:
        stop.set()
        await task


@pytest.mark.asyncio
async def test_send_command_times_out_without_result():
    def builder(req: Dict[str, Any]) -> List[Dict[str, Any]]:
        # Only an ack, no final result — client must time out.
        return [{"type": "ack", "status": "started", "message": "hang"}]

    port, task, stop = await _make_mock(builder)
    try:
        async with VivadoClient(host="127.0.0.1", port=port, reconnect_max_attempts=1) as vv:
            with pytest.raises(VivadoTimeoutError):
                await vv.send_command("slow", {}, timeout=0.3)
    finally:
        stop.set()
        await task


@pytest.mark.asyncio
async def test_connect_refused_raises_with_finite_attempts():
    # No server. With finite attempts, should raise instead of hanging.
    vv = VivadoClient(
        host="127.0.0.1",
        port=1,  # invalid low port
        reconnect_initial_delay=0.05,
        reconnect_max_delay=0.1,
        reconnect_max_attempts=2,
    )
    with pytest.raises(VivadoConnectionError):
        await vv.connect()
