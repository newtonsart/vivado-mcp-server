"""Asyncio client for the Vivado TCL plugin (NDJSON over local TCP).

Usage:
    client = VivadoClient()
    await client.connect()
    data = await client.send_command("get_project_info", {})

Features:
  * Persistent connection: Vivado is single-threaded; one connection at a time
    from this client.
  * Reader loop that receives all messages and dispatches them:
      - `result`       → resolves the request's Future
      - `progress`     → calls the registered progress callback
      - `ack`          → informational log (Futures stay open)
      - `notification` → fires global handlers (broadcast)
  * Per-command timeout (passed explicitly by the caller).
  * Automatic reconnection with exponential backoff.
  * Pending Futures are resolved with VivadoConnectionError if the connection
    drops mid-operation.

The client is safe to use from multiple coroutines: `send_command` can be
called concurrently; commands are naturally serialized in the TCL server
(FIFO queue).
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Awaitable, Callable, Dict, Optional

from vivado import protocol as proto
from vivado.exceptions import (
    VivadoConnectionError,
    VivadoProtocolError,
    VivadoRemoteError,
    VivadoTimeoutError,
)

log = logging.getLogger("vivado-mcp-socket.client")

ProgressCallback = Callable[[int, str], Awaitable[None] | None]
NotificationCallback = Callable[[str, Dict[str, Any]], Awaitable[None] | None]


class VivadoClient:
    """Asyncio TCP client for the Vivado TCL plugin."""

    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 7654,
        *,
        reconnect_initial_delay: float = 1.0,
        reconnect_max_delay: float = 30.0,
        reconnect_max_attempts: int = 0,
    ) -> None:
        self.host = host
        self.port = port
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._reader_task: Optional[asyncio.Task] = None

        # req_id → (Future, progress_cb, command)
        self._pending: Dict[str, Dict[str, Any]] = {}
        self._notification_handlers: list[NotificationCallback] = []

        # Synchronization
        self._connect_lock = asyncio.Lock()
        self._write_lock = asyncio.Lock()
        self._connected = False

        # Reconnection backoff
        self._reconnect_initial = reconnect_initial_delay
        self._reconnect_max = reconnect_max_delay
        self._reconnect_max_attempts = reconnect_max_attempts

    # -------------------------------------------------------------------------
    # Public API
    # -------------------------------------------------------------------------
    async def __aenter__(self) -> "VivadoClient":
        await self.connect()
        return self

    async def __aexit__(self, exc_type, exc, tb) -> None:
        await self.close()

    @property
    def connected(self) -> bool:
        return self._connected and self._writer is not None and not self._writer.is_closing()

    def add_notification_handler(self, handler: NotificationCallback) -> None:
        """Register a callback that receives (event, data) for each notification."""
        self._notification_handlers.append(handler)

    async def connect(self) -> None:
        """Establish connection. Idempotent; does nothing if already connected.

        Applies exponential backoff on failure up to `reconnect_max_attempts`
        (0 = unlimited).
        """
        async with self._connect_lock:
            if self.connected:
                return
            await self._do_connect_with_backoff()

    async def _do_connect_with_backoff(self) -> None:
        attempt = 0
        delay = self._reconnect_initial
        while True:
            attempt += 1
            try:
                log.info("connecting to %s:%d (attempt %d)", self.host, self.port, attempt)
                reader, writer = await asyncio.open_connection(
                    self.host, self.port, limit=64 * 1024 * 1024
                )
                self._reader = reader
                self._writer = writer
                self._connected = True
                self._reader_task = asyncio.create_task(
                    self._reader_loop(), name="vivado-mcp-reader"
                )
                log.info("connected to Vivado plugin at %s:%d", self.host, self.port)
                return
            except (OSError, ConnectionRefusedError) as exc:
                log.warning("connect failed: %s (will retry in %.1fs)", exc, delay)
                if (
                    self._reconnect_max_attempts
                    and attempt >= self._reconnect_max_attempts
                ):
                    raise VivadoConnectionError(
                        f"Could not connect to Vivado at {self.host}:{self.port} "
                        f"after {attempt} attempts: {exc}"
                    ) from exc
                await asyncio.sleep(delay)
                delay = min(delay * 2, self._reconnect_max)

    async def close(self) -> None:
        """Close the connection cleanly."""
        self._connected = False
        if self._reader_task and not self._reader_task.done():
            self._reader_task.cancel()
            try:
                await self._reader_task
            except (asyncio.CancelledError, Exception):
                pass
            self._reader_task = None
        if self._writer is not None:
            try:
                self._writer.close()
                await self._writer.wait_closed()
            except Exception:  # noqa: BLE001
                pass
            self._writer = None
            self._reader = None
        self._fail_pending(VivadoConnectionError("connection closed"))

    # -------------------------------------------------------------------------
    # send_command: main API for MCP tools
    # -------------------------------------------------------------------------
    async def send_command(
        self,
        command: str,
        params: Optional[Dict[str, Any]] = None,
        *,
        progress_cb: Optional[ProgressCallback] = None,
        timeout: float = 30.0,
    ) -> Dict[str, Any]:
        """Send a command and wait for the final `result`.

        If a `progress` message arrives, calls `progress_cb(percent, message)`
        (may be a coroutine or a plain function).

        Args:
            command: name of the command registered in the TCL plugin.
            params: parameter dict (serialized to JSON).
            progress_cb: optional. Called for each progress event.
            timeout: seconds to wait for the `result` to arrive.

        Returns:
            The `data` field of the `result` as a dict (may be empty).

        Raises:
            VivadoConnectionError: if the connection drops.
            VivadoTimeoutError: if no `result` arrives before `timeout`.
            VivadoRemoteError: if the server returns `status=error`.
        """
        if not self.connected:
            await self.connect()

        request = proto.Request(command=command, params=params or {})
        future: asyncio.Future = asyncio.get_event_loop().create_future()
        self._pending[request.id] = {
            "future": future,
            "progress_cb": progress_cb,
            "command": command,
        }
        line = request.to_json_line()

        try:
            async with self._write_lock:
                if self._writer is None:
                    raise VivadoConnectionError("writer is None (not connected)")
                self._writer.write((line + "\n").encode("utf-8"))
                await self._writer.drain()
        except (OSError, ConnectionError) as exc:
            self._pending.pop(request.id, None)
            self._connected = False
            raise VivadoConnectionError(f"write failed: {exc}") from exc

        try:
            # asyncio.shield() protects the underlying future from being cancelled
            # if this coroutine is cancelled externally (e.g. Claude Desktop's MCP
            # framework timeout). Without shield, the cancellation propagates to the
            # future → _fail_pending tears down the entire TCP connection.
            # With shield, only the wrapper is cancelled; the future and TCP
            # connection survive and the late response is silently discarded by the
            # reader loop (no pending entry to match).
            result_msg: proto.Result = await asyncio.wait_for(
                asyncio.shield(future), timeout=timeout
            )
        except asyncio.TimeoutError as exc:
            # Timeout: the command was already sent to Vivado and is still running.
            # Remove from pending to avoid a memory leak; any late response will
            # arrive at the reader loop and be silently ignored.
            self._pending.pop(request.id, None)
            raise VivadoTimeoutError(command, timeout) from exc
        except asyncio.CancelledError:
            # The MCP framework cancelled this coroutine (its own timeout / shutdown).
            # shield() already prevented the underlying future from being cancelled.
            # Clean up pending and re-raise so asyncio can manage the lifecycle.
            self._pending.pop(request.id, None)
            raise

        if result_msg.status == "ok":
            return result_msg.data or {}
        # status == "error"
        err = result_msg.error or {}
        raise VivadoRemoteError(
            code=str(err.get("code", "UNKNOWN")),
            message=str(err.get("message", "unknown error")),
            detail=err.get("detail"),
            command=command,
            request_id=request.id,
            raw=err,
        )

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------
    async def ping(self, timeout: float = 5.0) -> Dict[str, Any]:
        """Quick health check against the TCL plugin."""
        return await self.send_command("ping", {}, timeout=timeout)

    async def run_tcl(self, expr: str, timeout: float = 600.0) -> Dict[str, Any]:
        """Escape hatch: execute an arbitrary TCL snippet."""
        return await self.send_command("run_tcl", {"expr": expr}, timeout=timeout)

    # -------------------------------------------------------------------------
    # Reader loop: reads lines and dispatches messages
    # -------------------------------------------------------------------------
    async def _reader_loop(self) -> None:
        assert self._reader is not None
        try:
            while True:
                line = await self._reader.readline()
                if not line:
                    # EOF: the server closed the connection.
                    log.warning("EOF from Vivado plugin — connection closed")
                    break
                text = line.decode("utf-8", errors="replace").rstrip("\r\n")
                if not text:
                    continue
                try:
                    msg = proto.parse_incoming(text)
                except ValueError as exc:
                    log.warning("invalid message from server: %s (line=%r)", exc, text)
                    continue
                await self._dispatch_message(msg)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            log.exception("reader loop crashed")
        finally:
            self._connected = False
            self._fail_pending(VivadoConnectionError("connection lost"))

    async def _dispatch_message(self, msg: Any) -> None:
        if isinstance(msg, proto.Result):
            pending = self._pending.pop(msg.id, None)
            if not pending:
                log.warning("received result for unknown request id=%s", msg.id)
                return
            fut: asyncio.Future = pending["future"]
            if not fut.done():
                fut.set_result(msg)
            return

        if isinstance(msg, proto.Progress):
            pending = self._pending.get(msg.id)
            if not pending:
                log.debug("progress for unknown request id=%s", msg.id)
                return
            cb: Optional[ProgressCallback] = pending.get("progress_cb")
            if cb is None:
                return
            try:
                rv = cb(msg.percent, msg.message)
                if asyncio.iscoroutine(rv):
                    await rv
            except Exception:  # noqa: BLE001
                log.exception("progress callback raised")
            return

        if isinstance(msg, proto.Ack):
            pending = self._pending.get(msg.id)
            if pending:
                log.info(
                    "ack %s: %s",
                    pending.get("command", "?"),
                    msg.message,
                )
            else:
                log.debug("ack for unknown request id=%s", msg.id)
            return

        if isinstance(msg, proto.Notification):
            log.info("notification: %s %s", msg.event, msg.data)
            for handler in list(self._notification_handlers):
                try:
                    rv = handler(msg.event, msg.data)
                    if asyncio.iscoroutine(rv):
                        await rv
                except Exception:  # noqa: BLE001
                    log.exception("notification handler raised")
            return

        log.warning("unhandled message: %r", msg)

    def _fail_pending(self, exc: BaseException) -> None:
        """Mark all pending Futures with an exception."""
        if not self._pending:
            return
        for req_id, pending in list(self._pending.items()):
            fut: asyncio.Future = pending["future"]
            if not fut.done():
                fut.set_exception(exc)
        self._pending.clear()
