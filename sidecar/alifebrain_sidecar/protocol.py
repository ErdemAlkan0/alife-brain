"""Wire format shared with mod/.../ALifeBrain/Bridge.lua. Spec: docs/bridge-protocol.md."""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from typing import Any

PROTOCOL = 1

# JSON lines in .txt files: B42's getFileWriter only writes txt/ini/cfg/json/lua/log.
REQ_FILE = "alifebrain_req.txt"
CLAIMED_FILE = "alifebrain_req.processing"
RES_FILE = "alifebrain_res.txt"
RES_TMP_FILE = "alifebrain_res.tmp"

MAX_LINE_LENGTH = 16000
MAX_ID_LENGTH = 200

_TYPE_PATTERN = re.compile(r"^[a-z_]{1,32}$")


class ProtocolError(ValueError):
    """A request line that does not follow the protocol."""


@dataclass(frozen=True)
class Ack:
    sid: str
    rseq: int


@dataclass(frozen=True)
class Request:
    id: str
    session: str
    type: str
    ts: int
    data: Any
    ack: Ack | None


def _require_string(message: dict, key: str, max_length: int = MAX_ID_LENGTH) -> str:
    value = message.get(key)
    if not isinstance(value, str) or not value or len(value) > max_length:
        raise ProtocolError(f"bad_{key}")
    return value


def _parse_ack(value: Any) -> Ack | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ProtocolError("bad_ack")
    sid, rseq = value.get("sid"), value.get("rseq")
    if not isinstance(sid, str) or isinstance(rseq, bool) or not isinstance(rseq, (int, float)):
        raise ProtocolError("bad_ack")
    if rseq < 0 or rseq != int(rseq):
        raise ProtocolError("bad_ack")
    return Ack(sid=sid, rseq=int(rseq))


def parse_request(line: str) -> Request:
    if len(line) > MAX_LINE_LENGTH:
        raise ProtocolError("line_too_long")
    try:
        message = json.loads(line)
    except json.JSONDecodeError as error:
        raise ProtocolError(f"bad_json: {error.msg}") from None
    if not isinstance(message, dict):
        raise ProtocolError("not_an_object")
    if message.get("v") != PROTOCOL:
        raise ProtocolError("bad_version")

    kind = message.get("type")
    if not isinstance(kind, str) or not _TYPE_PATTERN.match(kind):
        raise ProtocolError("bad_type")
    ts = message.get("ts")
    if isinstance(ts, bool) or not isinstance(ts, (int, float)) or not math.isfinite(ts):
        raise ProtocolError("bad_ts")

    return Request(
        id=_require_string(message, "id"),
        session=_require_string(message, "sess"),
        type=kind,
        ts=int(ts),
        data=message.get("data"),
        ack=_parse_ack(message.get("ack")),
    )


def encode_line(payload: dict) -> str:
    """One JSON line, ASCII only (the Lua decoder handles \\uXXXX escapes)."""
    return json.dumps(payload, ensure_ascii=True, separators=(",", ":"), allow_nan=False, sort_keys=True)


def status_payload(*, sid: str, beat: int, ts: int, version: str, session: str | None) -> dict:
    return {"v": PROTOCOL, "type": "status", "sid": sid, "beat": beat, "ts": ts, "ver": version, "sess": session}


def response_payload(*, rseq: int, re_id: str, ok: bool, data: Any = None, error: str | None = None) -> dict:
    payload = {"v": PROTOCOL, "type": "res", "rseq": rseq, "re": re_id, "ok": ok}
    if ok:
        payload["data"] = data
    else:
        payload["error"] = error or "sidecar_error"
    return payload


def push_payload(*, rseq: int, session: str | None, kind: str, data: Any) -> dict:
    return {"v": PROTOCOL, "type": "push", "rseq": rseq, "sess": session, "kind": kind, "data": data}
