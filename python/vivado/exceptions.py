"""Exception hierarchy for the Vivado MCP client."""

from __future__ import annotations

from typing import Any, Dict, Optional


class VivadoError(Exception):
    """Base error for the Vivado client."""


class VivadoConnectionError(VivadoError):
    """TCP connection error with the TCL plugin.

    Raised when:
      * Vivado is not running (ConnectionRefusedError)
      * The TCL plugin is not loaded (port closed)
      * The connection drops mid-operation (BrokenPipe, reset)
    """


class VivadoTimeoutError(VivadoError):
    """The command did not receive a `result` before the configured timeout."""

    def __init__(self, command: str, timeout: float) -> None:
        super().__init__(f"Command '{command}' timed out after {timeout:.1f}s")
        self.command = command
        self.timeout = timeout


class VivadoProtocolError(VivadoError):
    """An incoming message does not conform to the protocol (invalid JSON, missing fields)."""


class VivadoRemoteError(VivadoError):
    """The TCL server returned `status=error` in the `result`.

    Preserves the original payload for diagnostics.
    """

    def __init__(
        self,
        code: str,
        message: str,
        detail: Optional[str] = None,
        *,
        command: Optional[str] = None,
        request_id: Optional[str] = None,
        raw: Optional[Dict[str, Any]] = None,
    ) -> None:
        text = f"[{code}] {message}"
        if detail:
            text = f"{text}\n{detail}"
        super().__init__(text)
        self.code = code
        self.message = message
        self.detail = detail
        self.command = command
        self.request_id = request_id
        self.raw = raw or {}
