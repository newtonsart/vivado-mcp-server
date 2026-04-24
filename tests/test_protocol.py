"""Tests for `vivado_mcp_server.vivado.protocol`."""

from __future__ import annotations

import json

import pytest

from vivado_mcp_server.vivado import protocol as proto


def test_request_to_json_line_contains_fields():
    req = proto.Request(command="ping", params={"x": 1})
    line = req.to_json_line()
    obj = json.loads(line)
    assert obj["type"] == "request"
    assert obj["command"] == "ping"
    assert obj["params"] == {"x": 1}
    # `id` is a UUID string that should be generated automatically.
    assert isinstance(obj["id"], str) and len(obj["id"]) > 0
    # No embedded newline — NDJSON framing assumption.
    assert "\n" not in line


def test_parse_incoming_ack():
    msg = proto.parse_incoming(json.dumps({
        "type": "ack",
        "id": "abc",
        "status": "started",
        "message": "launched",
    }))
    assert isinstance(msg, proto.Ack)
    assert msg.id == "abc"
    assert msg.status == "started"
    assert msg.message == "launched"


def test_parse_incoming_progress_coerces_percent_to_int():
    msg = proto.parse_incoming(json.dumps({
        "type": "progress",
        "id": "abc",
        "percent": "42",
        "message": "synth",
    }))
    assert isinstance(msg, proto.Progress)
    assert msg.percent == 42
    assert isinstance(msg.percent, int)


def test_parse_incoming_result_ok():
    msg = proto.parse_incoming(json.dumps({
        "type": "result",
        "id": "abc",
        "status": "ok",
        "data": {"run": "synth_1"},
    }))
    assert isinstance(msg, proto.Result)
    assert msg.status == "ok"
    assert msg.data == {"run": "synth_1"}
    assert msg.error is None


def test_parse_incoming_result_error():
    msg = proto.parse_incoming(json.dumps({
        "type": "result",
        "id": "abc",
        "status": "error",
        "error": {"code": "BAD", "message": "no"},
    }))
    assert isinstance(msg, proto.Result)
    assert msg.status == "error"
    assert msg.error == {"code": "BAD", "message": "no"}


def test_parse_incoming_notification():
    msg = proto.parse_incoming(json.dumps({
        "type": "notification",
        "event": "run_complete",
        "data": {"run": "impl_1"},
    }))
    assert isinstance(msg, proto.Notification)
    assert msg.event == "run_complete"
    assert msg.data == {"run": "impl_1"}


def test_parse_incoming_rejects_unknown_type():
    with pytest.raises(ValueError, match="unknown message type"):
        proto.parse_incoming(json.dumps({"type": "bogus"}))


def test_parse_incoming_rejects_invalid_json():
    with pytest.raises(ValueError, match="invalid JSON"):
        proto.parse_incoming("{not-json")
