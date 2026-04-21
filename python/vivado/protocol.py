"""Types and helpers for the NDJSON protocol used between Python and the TCL plugin.

Channel format: each message is a JSON object on a single line terminated by
`\n`. There is no length prefix; parsers rely on `readline()` / `gets`
respectively.

Message types:
    request       (Python → TCL)
    ack           (TCL → Python, immediate, for long-running commands)
    progress      (TCL → Python, streaming)
    result        (TCL → Python, final, status=ok|error)
    notification  (TCL → Python, server-initiated event with no id)
"""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass, field
from typing import Any, Dict, Literal, Optional


MessageType = Literal["request", "ack", "progress", "result", "notification"]


@dataclass
class Request:
    """Request from the Python client to the TCL server."""

    command: str
    params: Dict[str, Any] = field(default_factory=dict)
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    type: Literal["request"] = "request"

    def to_json_line(self) -> str:
        return json.dumps(
            {
                "id": self.id,
                "type": self.type,
                "command": self.command,
                "params": self.params,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )


@dataclass
class Ack:
    """Notification that a long-running command has started (before the final result)."""

    id: str
    message: str
    status: str = "started"
    type: Literal["ack"] = "ack"


@dataclass
class Progress:
    """Progress event during a long-running command."""

    id: str
    percent: int
    message: str
    type: Literal["progress"] = "progress"


@dataclass
class Result:
    """Final response for a command.

    If `status == "ok"`, `data` contains the payload. If `status == "error"`,
    `error` contains {code, message, detail}.
    """

    id: str
    status: Literal["ok", "error"]
    data: Optional[Dict[str, Any]] = None
    error: Optional[Dict[str, Any]] = None
    type: Literal["result"] = "result"


@dataclass
class Notification:
    """Server-initiated event with no associated request."""

    event: str
    data: Dict[str, Any] = field(default_factory=dict)
    type: Literal["notification"] = "notification"


# -----------------------------------------------------------------------------
# Incoming line parser. Returns an instance of the appropriate dataclass.
# -----------------------------------------------------------------------------
def parse_incoming(line: str) -> Ack | Progress | Result | Notification:
    """Decode an NDJSON line received from the TCL plugin.

    Raises:
        ValueError: if the JSON is invalid or the message type is unrecognized.
    """
    try:
        obj = json.loads(line)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON from server: {exc}") from exc

    msg_type = obj.get("type")
    if msg_type == "ack":
        return Ack(
            id=obj.get("id", ""),
            message=obj.get("message", ""),
            status=obj.get("status", "started"),
        )
    if msg_type == "progress":
        return Progress(
            id=obj.get("id", ""),
            percent=int(obj.get("percent", 0) or 0),
            message=obj.get("message", ""),
        )
    if msg_type == "result":
        return Result(
            id=obj.get("id", ""),
            status=obj.get("status", "ok"),
            data=obj.get("data"),
            error=obj.get("error"),
        )
    if msg_type == "notification":
        return Notification(
            event=obj.get("event", ""),
            data=obj.get("data", {}) or {},
        )
    raise ValueError(f"unknown message type: {msg_type!r}")
