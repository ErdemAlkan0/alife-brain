"""Sidecar main loop: claim requests, dispatch them, publish status + responses."""

from __future__ import annotations

import logging
import secrets
import time
from collections import OrderedDict
from dataclasses import dataclass
from typing import Any, Callable

from . import __version__
from .events import EventStore
from .files import FileBridge
from .protocol import (
    PROTOCOL,
    ProtocolError,
    Request,
    encode_line,
    parse_request,
    response_payload,
    status_payload,
)

log = logging.getLogger(__name__)

FEATURES = ["ping", "event"]

# Request types that are acknowledged implicitly and never get a response line.
NO_REPLY_TYPES = frozenset({"event", "ack"})


def wall_clock_ms() -> int:
    return int(time.time() * 1000)


class HandlerError(Exception):
    """Raised by a handler to send ok=false with a short error code."""


@dataclass
class Outgoing:
    rseq: int
    created_ms: int
    session: str | None
    payload: dict


class Sidecar:
    def __init__(
        self,
        bridge: FileBridge,
        events: EventStore,
        *,
        clock: Callable[[], int] = wall_clock_ms,
        sid: str | None = None,
        heartbeat_ms: int = 1000,
        keep_ms: int = 120_000,
        stale_request_ms: int = 30_000,
        max_outgoing: int = 500,
    ) -> None:
        self.bridge = bridge
        self.events = events
        self.clock = clock
        self.sid = sid or secrets.token_hex(4)
        self.heartbeat_ms = heartbeat_ms
        self.keep_ms = keep_ms
        self.stale_request_ms = stale_request_ms
        self.max_outgoing = max_outgoing

        self.beat = 0
        self.rseq = 0
        self.session: str | None = None
        self.outgoing: list[Outgoing] = []
        self.seen_ids: OrderedDict[str, None] = OrderedDict()
        self.last_publish_ms: int | None = None
        self.dirty = True
        self.stats: dict[str, int] = {}

        self.handlers: dict[str, Callable[[Request, int], Any]] = {
            "hello": self._hello,
            "ping": self._ping,
            "event": self._event,
            "ack": lambda request, now: None,
        }

    # -- loop -----------------------------------------------------------------

    def step(self) -> None:
        now = self.clock()
        for line in self.bridge.claim():
            self._handle_line(line, now)
        self._prune(now)
        due = self.last_publish_ms is None or now - self.last_publish_ms >= self.heartbeat_ms
        if self.dirty or due:
            self._publish(now)

    def _publish(self, now: int) -> None:
        self.beat += 1
        status = status_payload(sid=self.sid, beat=self.beat, ts=now, version=__version__, session=self.session)
        lines = [encode_line(status)] + [encode_line(item.payload) for item in self.outgoing]
        if self.bridge.publish(lines):
            self.last_publish_ms = now
            self.dirty = False
        else:
            self._count("publish_retry")

    # -- requests -------------------------------------------------------------

    def _count(self, key: str) -> None:
        self.stats[key] = self.stats.get(key, 0) + 1

    def _remember(self, request_id: str) -> bool:
        """False when this id was already handled (a claimed file read twice)."""
        if request_id in self.seen_ids:
            return False
        self.seen_ids[request_id] = None
        while len(self.seen_ids) > 2000:
            self.seen_ids.popitem(last=False)
        return True

    def _handle_line(self, line: str, now: int) -> None:
        if not line.strip():
            return
        try:
            request = parse_request(line)
        except ProtocolError as error:
            self._count("bad_line")
            log.warning("ignored request line (%s): %.120s", error, line)
            return
        if not self._remember(request.id):
            self._count("duplicate")
            return
        if request.ack is not None and request.ack.sid == self.sid:
            self._apply_ack(request.ack.rseq)
        if request.session != self.session:
            self._switch_session(request.session)
        if request.type not in NO_REPLY_TYPES and now - request.ts > self.stale_request_ms:
            self._count("stale")
            log.info("dropped stale %s request %s (%d ms old)", request.type, request.id, now - request.ts)
            return

        self._count(f"type:{request.type}")
        handler = self.handlers.get(request.type)
        if handler is None:
            self._reply(request, now, ok=False, error="unknown_type")
            return
        try:
            data = handler(request, now)
        except HandlerError as error:
            self._reply(request, now, ok=False, error=str(error) or "handler_error")
            return
        except Exception:
            log.exception("handler for %s failed", request.type)
            self._reply(request, now, ok=False, error="internal_error")
            return
        if request.type not in NO_REPLY_TYPES:
            self._reply(request, now, ok=True, data=data)

    def _switch_session(self, session: str) -> None:
        log.info("game session %s (was %s)", session, self.session)
        self.session = session
        before = len(self.outgoing)
        self.outgoing = [item for item in self.outgoing if item.session == session]
        if len(self.outgoing) != before:
            self.dirty = True

    def _apply_ack(self, rseq: int) -> None:
        before = len(self.outgoing)
        self.outgoing = [item for item in self.outgoing if item.rseq > rseq]
        if len(self.outgoing) != before:
            self.dirty = True

    def _prune(self, now: int) -> None:
        before = len(self.outgoing)
        self.outgoing = [item for item in self.outgoing if now - item.created_ms <= self.keep_ms]
        if len(self.outgoing) > self.max_outgoing:
            self.outgoing = self.outgoing[-self.max_outgoing:]
        if len(self.outgoing) != before:
            self.dirty = True

    def _reply(self, request: Request, now: int, *, ok: bool, data: Any = None, error: str | None = None) -> None:
        self.rseq += 1
        payload = response_payload(rseq=self.rseq, re_id=request.id, ok=ok, data=data, error=error)
        self.outgoing.append(Outgoing(rseq=self.rseq, created_ms=now, session=request.session, payload=payload))
        self.dirty = True

    # -- handlers -------------------------------------------------------------

    def _hello(self, request: Request, now: int) -> dict:
        meta = request.data if isinstance(request.data, dict) else {}
        log.info(
            "hello from %s %s (game %s, A-Life %s)",
            meta.get("mod"), meta.get("modVersion"), meta.get("game"), meta.get("alife"),
        )
        return {"version": __version__, "protocol": PROTOCOL, "sid": self.sid, "features": FEATURES}

    def _ping(self, request: Request, now: int) -> dict:
        return {"pong": True, "echo": request.data, "sidecarTs": now}

    def _event(self, request: Request, now: int) -> None:
        if not isinstance(request.data, dict) or not isinstance(request.data.get("kind"), str):
            raise HandlerError("bad_event")
        self.events.append(ts=request.ts, received_ts=now, session=request.session, request_id=request.id,
                           event=request.data)
        log.info("event %s %s", request.data.get("kind"), (request.data.get("npc") or {}).get("uid"))
