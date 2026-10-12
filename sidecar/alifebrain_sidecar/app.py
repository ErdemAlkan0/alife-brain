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
from .config import DialogueSettings, MemorySettings
from .dataset import DatasetStore
from .dialogue import BadRequest, InvalidReply, build_messages, parse_reply
from .dialogue import parse_request as parse_dialogue
from .events import EventStore
from .experience import apply_event
from .files import FileBridge
from .llm import LLMError
from .memory import GOAL_HALF_LIFE_MS, MemoryStore
from .protocol import (
    PROTOCOL,
    ProtocolError,
    Request,
    encode_line,
    parse_request,
    response_payload,
    status_payload,
)
from .summary import InvalidSummary, build_summary_messages, parse_summary

log = logging.getLogger(__name__)

# Request types that are acknowledged implicitly and never get a response line.
NO_REPLY_TYPES = frozenset({"event", "ack"})
MOODS_PER_REQUEST = 32


def wall_clock_ms() -> int:
    return int(time.time() * 1000)


def _counts(value: Any, limit: int) -> str:
    """'key xN' for the largest counts of a {key: count} table (the game may send [] for {})."""
    items = [(key, count) for key, count in (value.items() if isinstance(value, dict) else [])
             if isinstance(count, (int, float)) and not isinstance(count, bool)]
    items.sort(key=lambda item: -item[1])
    return ", ".join(f"{key} x{int(count)}" for key, count in items[:limit])


def policy_summary(data: dict) -> str:
    """One log line for a policy_stats event (the game's Control.stats under policy control)."""
    parts = []
    for chain in ("decision", "response"):
        stats = data.get(chain) if isinstance(data.get(chain), dict) else {}
        parts.append(f"{chain}: asked {stats.get('asked', 0)}, ran {stats.get('ran', 0)}, nothing to do "
                     f"{stats.get('declined', 0)}, near a player {stats.get('near', 0)}, left to A-Life "
                     f"{stats.get('left', 0)}")
    for label, key in (("ran", "modules"), ("left to A-Life", "reasons")):
        counts = _counts(data.get(key), 8)
        if counts:
            parts.append(f"{label}: {counts}")
    return "; ".join(parts)


class HandlerError(Exception):
    """Raised by a handler to send ok=false with a short error code."""


@dataclass
class Deferred:
    """A handler result that is still being computed off the main thread."""

    future: Future
    finish: Callable[[Any], Any]


@dataclass
class SummaryJob:
    candidate: Any
    future: Future


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
        dataset: DatasetStore | None = None,
        provider: Any = None,
        dialogue: DialogueSettings | None = None,
        memory_settings: MemorySettings | None = None,
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
        self.dataset = dataset
        self.provider = provider
        self.dialogue = dialogue or DialogueSettings()
        self.memory_settings = memory_settings or MemorySettings()
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
        self.summary_job: SummaryJob | None = None
        self.last_summary_ms: int | None = None
        self.summary_retry: dict[tuple[str, str], int] = {}

        self.handlers: dict[str, Callable[[Request, int], Any]] = {
            "hello": self._hello,
            "ping": self._ping,
            "event": self._event,
            "dialogue": self._dialogue,
            "history": self._history,
            "moods": self._moods,
            "ack": lambda request, now: None,
        }

    @property
    def features(self) -> list[str]:
        features = ["ping", "event"]
        if self.dataset is not None:
            features.append("dataset")
        if self.memory is not None:
            features += ["history", "moods"]
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
        self._maybe_summarize(now)
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

    def _maybe_summarize(self, now: int) -> None:
        """Rewrites one layer's old memories into a summary now and then, while no reply is
        being written (summary.py). A failed one is tried again after summary_retry_s."""
        settings = self.memory_settings
        if self.memory is None or self.provider is None or not settings.summarize:
            return
        job = self.summary_job
        if job is not None:
            if not job.future.done():
                return
            self.summary_job = None
            key = (job.candidate.scope, job.candidate.key)
            try:
                summary = parse_summary(job.future.result())
            except (LLMError, InvalidSummary) as error:
                self.summary_retry[key] = now + settings.summary_retry_s * 1000
                self._count("summary_failed")
                log.warning("memory summary for %s %s failed: %s", key[0], key[1], error)
                return
            except Exception:
                self.summary_retry[key] = now + settings.summary_retry_s * 1000
                log.exception("memory summary for %s %s failed", key[0], key[1])
                return
            self.memory.apply_summary(job.candidate, summary)
            self._count("summaries")
            log.info("summarized %d old memories of %s %s: %r", len(job.candidate.ids), key[0], key[1], summary)
            return
        if self.inflight or self.health_ok is False:
            return
        if self.last_summary_ms is not None and now - self.last_summary_ms < settings.summary_every_s * 1000:
            return
        self.summary_retry = {key: until for key, until in self.summary_retry.items() if until > now}
        candidate = self.memory.summary_candidate(after=settings.summary_after, keep_recent=settings.keep_recent,
                                                  skip=set(self.summary_retry))
        self.last_summary_ms = now
        if candidate is None:
            return
        messages = build_summary_messages(candidate, self.memory.layer_name(candidate.scope, candidate.key))
        self.summary_job = SummaryJob(candidate, self.executor.submit(
            self.provider.chat, messages, max_tokens=settings.summary_max_tokens, temperature=0.3,
            timeout=self.dialogue.timeout_s))

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
            "hello from %s %s (game %s, A-Life %s, save %s)",
            meta.get("mod"), meta.get("modVersion"), meta.get("game"), meta.get("alife"), request.world,
        )
        return {"version": __version__, "protocol": PROTOCOL, "sid": self.sid, "features": self.features,
                "provider": getattr(self.provider, "name", None)}

    def _ping(self, request: Request, now: int) -> dict:
        return {"pong": True, "echo": request.data, "sidecarTs": now}

    def _event(self, request: Request, now: int) -> None:
        if not isinstance(request.data, dict) or not isinstance(request.data.get("kind"), str):
            raise HandlerError("bad_event")
        if request.data["kind"] == "decision_samples":
            # Training data, not memories: kept apart from events.jsonl.
            if self.dataset is None:
                raise HandlerError("dataset_unavailable")
            before = self.dataset.count
            stored = self.dataset.add_batch(request.data, ts=request.ts, session=request.session)
            self.stats["samples"] = self.stats.get("samples", 0) + stored
            if before // 500 != self.dataset.count // 500 or before == 0:
                log.info("dataset: %d decisions stored (%d rejected)", self.dataset.count, self.dataset.rejected)
            return
        self.events.append(ts=request.ts, received_ts=now, session=request.session, request_id=request.id,
                           event=request.data)
        if request.data["kind"] == "policy_stats":
            log.info("policy control: %s", policy_summary(request.data))
            return
        if self.memory is not None:
            apply_event(self.memory, request.data, request.ts, world=request.world)
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
        history = self.memory.recent_turns(uid, player_key, settings.history_turns)
        goal = self.memory.drive(uid, now)
        messages = build_messages(
            dialogue,
            memories=self.memory.recall(npc, query=dialogue.text, now=now, limit=settings.memories,
                                        world=request.world),
            history=history,
            trust=trust,
            fear=fear,
            goal=goal,
            summaries=self.memory.summaries(npc, world=request.world),
        )
        compact = build_messages(dialogue, memories=[], history=history[-2:], trust=trust, fear=fear, goal=goal,
                                 compact=True)
        log.debug("dialogue prompt for %s:\n%s", uid, "\n---\n".join(m["content"] for m in messages))
        future = self.executor.submit(self._ask_llm, messages, compact)

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
            if not dialogue.opening:  # an opening is a narration, not the stranger's words
                self.memory.add_turn(uid, player_key, ts=now, speaker="player", text=dialogue.text)
            self.memory.add_turn(uid, player_key, ts=done, speaker="npc", text=reply.say)
            if reply.memory_note:
                self.memory.add_memory("personal", uid, ts=done, kind="dialogue", text=reply.memory_note,
                                       importance=4, player_key=player_key)
            new_trust, new_fear = self.memory.shift_mood(uid, player_key, reply.trust_delta, reply.fear_delta, done)
            new_goal = self.memory.shift_drive(uid, reply.goal_delta, done)
            log.info("%s (%s) -> %r intent=%s%s trust=%d fear=%d goal=%d (%d ms)", npc.name or uid, uid, reply.say,
                     reply.intent, f" item={reply.item}" if reply.item else "", new_trust, new_fear, new_goal,
                     done - now)
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
                    "fear": new_fear, "goalDelta": reply.goal_delta, "goal": new_goal}

        return Deferred(future, finish)

    def _ask_llm(self, messages: list[dict], compact: list[dict] | None) -> str:
        """The reply to messages (runs on a worker thread). When the provider refuses them with
        HTTP 400 (Player2: "user input rejected", a content filter it seems, now and then tripped
        by a war-torn prompt: play test 2026-10-11, twice in a day, the same request refused
        again on retry), asks once more with the short prompt, if there is time left for it."""
        settings = self.dialogue
        started = time.monotonic()
        try:
            return self.provider.chat(messages, max_tokens=settings.max_tokens, temperature=settings.temperature,
                                      timeout=settings.timeout_s)
        except LLMError as error:
            spent = time.monotonic() - started
            if compact is None or error.code != "http_400" or spent > settings.timeout_s / 2:
                raise
            log.info("the LLM refused the full prompt (%s); asking again with the short one", error.detail[:80])
            return self.provider.chat(compact, max_tokens=settings.max_tokens, temperature=settings.temperature,
                                      timeout=max(5.0, settings.timeout_s - spent))

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
        return {"uid": uid, "name": npc.name if npc else None, "trust": trust, "fear": fear,
                "goal": self.memory.drive(uid, now), "turns": turns}

    def _moods(self, request: Request, now: int) -> dict:
        """Stored trust / fear (toward one player) and goal of NPCs the game's policy is about to
        read; only NPCs with something stored are listed (the rest start at 0)."""
        if self.memory is None:
            raise HandlerError("moods_unavailable")
        data = request.data if isinstance(request.data, dict) else {}
        player_key, uids = data.get("playerKey"), data.get("uids")
        if not isinstance(player_key, str) or not player_key or not isinstance(uids, list):
            raise HandlerError("uids_or_player_missing")
        wanted = [uid for uid in uids if isinstance(uid, str) and uid][:MOODS_PER_REQUEST]
        return {"moods": self.memory.moods(wanted, player_key, now), "goalHalfLifeMs": GOAL_HALF_LIFE_MS}
