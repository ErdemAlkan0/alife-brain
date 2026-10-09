"""Sidecar main loop: claim requests, dispatch them, publish status + responses.

Slow work (LLM calls, provider health checks) runs on a small thread pool so the loop
keeps publishing heartbeats; results are collected and memory is written on the main
thread only.
"""

from __future__ import annotations

import logging
import secrets
import time
from collections import OrderedDict
from concurrent.futures import Executor, Future, ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any, Callable

from . import __version__
from .config import DialogueSettings
from .dialogue import BadRequest, InvalidReply, build_messages, parse_reply
from .dialogue import parse_request as parse_dialogue
from .events import EventStore
from .experience import apply_event
from .files import FileBridge
from .llm import LLMError
from .memory import MemoryStore
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

# Request types that are acknowledged implicitly and never get a response line.
NO_REPLY_TYPES = frozenset({"event", "ack"})


def wall_clock_ms() -> int:
    return int(time.time() * 1000)


class HandlerError(Exception):
    """Raised by a handler to send ok=false with a short error code."""


@dataclass
class Deferred:
    """A handler result that is still being computed off the main thread."""

    future: Future
    finish: Callable[[Any], Any]


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
        memory: MemoryStore | None = None,
        provider: Any = None,
        dialogue: DialogueSettings | None = None,
        executor: Executor | None = None,
        health_interval_ms: int = 60_000,
        clock: Callable[[], int] = wall_clock_ms,
        sid: str | None = None,
        heartbeat_ms: int = 1000,
        keep_ms: int = 120_000,
        stale_request_ms: int = 30_000,
        max_outgoing: int = 500,
    ) -> None:
        self.bridge = bridge
        self.events = events
        self.memory = memory
        self.provider = provider
        self.dialogue = dialogue or DialogueSettings()
        self.executor = executor or ThreadPoolExecutor(max_workers=2, thread_name_prefix="alifebrain")
        self.health_interval_ms = health_interval_ms
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
        self.inflight: list[tuple[Request, Deferred]] = []
        self.seen_ids: OrderedDict[str, None] = OrderedDict()
        self.last_publish_ms: int | None = None
        self.dirty = True
        self.stats: dict[str, int] = {}
        self.health_future: Future | None = None
        self.last_health_ms: int | None = None
        self.health_ok: bool | None = None

        self.handlers: dict[str, Callable[[Request, int], Any]] = {
            "hello": self._hello,
            "ping": self._ping,
            "event": self._event,
            "dialogue": self._dialogue,
            "history": self._history,
            "ack": lambda request, now: None,
        }

    @property
    def features(self) -> list[str]:
        features = ["ping", "event"]
        if self.memory is not None:
            features.append("history")
        if self.memory is not None and self.provider is not None:
            features += ["dialogue", "actions"]
        return features

    def close(self) -> None:
        self.executor.shutdown(wait=False, cancel_futures=True)

    # -- loop -----------------------------------------------------------------

    def step(self) -> None:
        now = self.clock()
        for line in self.bridge.claim():
            self._handle_line(line, now)
        self._collect()
        self._check_health(now)
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
        if isinstance(data, Deferred):
            self.inflight.append((request, data))
        elif request.type not in NO_REPLY_TYPES:
            self._reply(request, now, ok=True, data=data)

    def _collect(self) -> None:
        if not self.inflight:
            return
        pending = []
        for request, deferred in self.inflight:
            if not deferred.future.done():
                pending.append((request, deferred))
                continue
            now = self.clock()
            try:
                data = deferred.finish(deferred.future.result())
            except HandlerError as error:
                self._reply(request, now, ok=False, error=str(error) or "handler_error")
            except LLMError as error:
                self._count(f"llm:{error.code}")
                log.warning("%s request %s failed: %s", request.type, request.id, error)
                self._reply(request, now, ok=False, error=error.code)
            except Exception:
                log.exception("deferred %s request %s failed", request.type, request.id)
                self._reply(request, now, ok=False, error="internal_error")
            else:
                self._reply(request, now, ok=True, data=data)
        self.inflight = pending

    def _check_health(self, now: int) -> None:
        health = getattr(self.provider, "health", None)
        if health is None or self.health_interval_ms <= 0:
            return
        if self.health_future is not None:
            if not self.health_future.done():
                return
            try:
                result = self.health_future.result()
            except Exception as error:
                if self.health_ok is not False:
                    log.warning("%s is not reachable (%s); NPCs fall back to A-Life lines",
                                getattr(self.provider, "name", "provider"), error)
                self.health_ok = False
            else:
                if self.health_ok is not True:
                    log.info("%s reachable: %s", getattr(self.provider, "name", "provider"), result)
                self.health_ok = True
            self.health_future = None
        if self.last_health_ms is None or now - self.last_health_ms >= self.health_interval_ms:
            self.last_health_ms = now
            self.health_future = self.executor.submit(health)

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
        return {"version": __version__, "protocol": PROTOCOL, "sid": self.sid, "features": self.features,
                "provider": getattr(self.provider, "name", None)}

    def _ping(self, request: Request, now: int) -> dict:
        return {"pong": True, "echo": request.data, "sidecarTs": now}

    def _event(self, request: Request, now: int) -> None:
        if not isinstance(request.data, dict) or not isinstance(request.data.get("kind"), str):
            raise HandlerError("bad_event")
        self.events.append(ts=request.ts, received_ts=now, session=request.session, request_id=request.id,
                           event=request.data)
        if self.memory is not None:
            apply_event(self.memory, request.data, request.ts)
        log.info("event %s %s", request.data.get("kind"), (request.data.get("npc") or {}).get("uid"))

    def _dialogue(self, request: Request, now: int) -> Deferred:
        if self.memory is None or self.provider is None:
            raise HandlerError("dialogue_unavailable")
        try:
            dialogue = parse_dialogue(request.data)
        except BadRequest as error:
            raise HandlerError(str(error)) from None
        uid, player_key = dialogue.npc.uid, dialogue.player_key
        self.memory.upsert_npc(dialogue.npc, now)
        npc = self.memory.npc(uid) or dialogue.npc
        trust, fear = self.memory.mood(uid, player_key)
        settings = self.dialogue
        messages = build_messages(
            dialogue,
            memories=self.memory.recall(npc, query=dialogue.text, now=now, limit=settings.memories),
            history=self.memory.recent_turns(uid, player_key, settings.history_turns),
            trust=trust,
            fear=fear,
        )
        log.debug("dialogue prompt for %s:\n%s", uid, "\n---\n".join(m["content"] for m in messages))
        future = self.executor.submit(self.provider.chat, messages, max_tokens=settings.max_tokens,
                                      temperature=settings.temperature, timeout=settings.timeout_s)

        def finish(text: str) -> dict:
            try:
                reply = parse_reply(text, dialogue)
            except InvalidReply as error:
                self._count("invalid_reply")
                log.warning("invalid LLM reply for %s (%s): %.200r", uid, error, text)
                raise HandlerError("invalid_llm_reply") from None
            log.debug("raw LLM reply for %s: %.500r", uid, text)
            if (reply.raw_intent or "none").lower() != reply.intent or (reply.raw_item or None) != reply.item:
                log.info("reinterpreted LLM intent for %s: intent=%r item=%r -> intent=%s item=%s", uid,
                         reply.raw_intent, reply.raw_item, reply.intent, reply.item)
            done = self.clock()
            self.memory.add_turn(uid, player_key, ts=now, speaker="player", text=dialogue.text)
            self.memory.add_turn(uid, player_key, ts=done, speaker="npc", text=reply.say)
            if reply.memory_note:
                self.memory.add_memory("personal", uid, ts=done, kind="dialogue", text=reply.memory_note,
                                       importance=4, player_key=player_key)
            new_trust, new_fear = self.memory.shift_mood(uid, player_key, reply.trust_delta, reply.fear_delta, done)
            log.info("%s (%s) -> %r intent=%s%s trust=%d fear=%d (%d ms)", npc.name or uid, uid, reply.say,
                     reply.intent, f" item={reply.item}" if reply.item else "", new_trust, new_fear, done - now)
            trade = None
            if reply.deal_guard:
                log.info("%s give was part of a deal: put on the trade table instead (offer=%s wants=%s)", uid,
                         list(reply.trade_offer), list(reply.trade_wants))
            if reply.trade_decision is not None:
                trade = {"decision": reply.trade_decision, "npcOffer": list(reply.trade_offer),
                         "npcWants": list(reply.trade_wants)}
                log.info("%s trade decision=%s npc_offer=%s npc_wants=%s", uid, reply.trade_decision,
                         list(reply.trade_offer), list(reply.trade_wants))
            return {"say": reply.say, "intent": reply.intent, "item": reply.item, "trade": trade,
                    "trustDelta": reply.trust_delta, "fearDelta": reply.fear_delta, "trust": new_trust,
                    "fear": new_fear}

        return Deferred(future, finish)

    def _history(self, request: Request, now: int) -> dict:
        """Earlier conversation with one NPC, for the chat window."""
        if self.memory is None:
            raise HandlerError("history_unavailable")
        data = request.data if isinstance(request.data, dict) else {}
        uid, player_key = data.get("uid"), data.get("playerKey")
        if not isinstance(uid, str) or not uid or not isinstance(player_key, str) or not player_key:
            raise HandlerError("uid_or_player_missing")
        limit = data.get("limit")
        limit = max(1, min(60, limit)) if isinstance(limit, int) and not isinstance(limit, bool) else 30
        trust, fear = self.memory.mood(uid, player_key)
        npc = self.memory.npc(uid)
        turns = [{"speaker": speaker, "text": text, "ts": ts}
                 for speaker, text, ts in self.memory.recent_turns_with_time(uid, player_key, limit)]
        return {"uid": uid, "name": npc.name if npc else None, "trust": trust, "fear": fear, "turns": turns}
