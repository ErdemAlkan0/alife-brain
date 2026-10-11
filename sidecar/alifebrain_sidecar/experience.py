"""Turns game events from EventLog.lua into NPC memories and mood shifts."""

from __future__ import annotations

import re
from typing import Any

from .memory import MemoryStore, Npc, faction_key

HIT_TRUST, HIT_FEAR = -10, 8
REPEAT_WINDOW_MS = 60_000


def weapon_name(full_type: Any) -> str | None:
    """"Base.HuntingKnife" -> "hunting knife"; bare hands -> None."""
    if not isinstance(full_type, str) or not full_type:
        return None
    name = full_type.rsplit(".", 1)[-1]
    if name.lower() == "barehands":
        return None
    return re.sub(r"(?<=[a-z])(?=[A-Z])", " ", name).replace("_", " ").lower()


def _npc(event: dict) -> Npc | None:
    data = event.get("npc")
    if not isinstance(data, dict) or not isinstance(data.get("uid"), str):
        return None
    return Npc(uid=data["uid"], name=data.get("name"), faction_id=data.get("factionId"),
               group_id=data.get("groupId"), profile_id=data.get("profileId"))


def _recent(store: MemoryStore, scope: str, key: str | None, kind: str, since: int) -> bool:
    if not key:
        return False
    row = store.db.execute("SELECT 1 FROM memories WHERE scope = ? AND scope_key = ? AND kind = ? AND ts >= ? LIMIT 1",
                           (scope, key, kind, since)).fetchone()
    return row is not None


ITEM_WORDS = {"water": "water", "food": "food", "medicine": "medicine"}
FAILURES = {
    "no_item": "had none to spare",
    "too_far": "the stranger was too far away",
    "limit": "had already given the stranger enough for now",
    "low_trust": "did not trust the stranger enough",
    "refused": "could not do it right then",
    "changed": "the items were no longer there",
    "empty": "there was nothing on the table",
    "unpaid": "the stranger put nothing down in return",
}


def _names(value: Any) -> str:
    if not isinstance(value, list):
        return ""
    names = [str(name)[:60] for name in value[:10] if isinstance(name, str) and name]
    return ", ".join(names)


def _apply_action(store: MemoryStore, npc: Npc, player_key: str, event: dict, ts: int) -> int:
    """Records what really happened after the NPC's intent, both as a memory and as a
    "system" turn so the next prompt's conversation shows the outcome."""
    action, ok = event.get("action"), event.get("ok") is True
    who = npc.name or "The survivor"
    item = ITEM_WORDS.get(event.get("item"), "something")
    label = event.get("label") if isinstance(event.get("label"), str) else item
    why = FAILURES.get(event.get("reason"), "could not do it")
    if action == "give":
        memory = (f"I gave the stranger {label}." if ok else f"I meant to give the stranger {item} but {why}.")
        turn = (f"{who} handed over {label}." if ok else f"{who} did not hand over any {item}: {why}.")
        importance = 5 if ok else 3
    elif action == "follow":
        memory = "I agreed to travel with the stranger." if ok else f"I did not go with the stranger; I {why}."
        turn = f"{who} started following the stranger." if ok else f"{who} did not follow: {why}."
        importance = 5 if ok else 3
    elif action == "stay":
        memory, turn, importance = "I stopped and waited where the stranger left me.", f"{who} is waiting here.", 3
    elif action == "leave":
        memory, turn, importance = "I walked away from the stranger.", f"{who} ended the conversation.", 3
    elif action == "trade":
        given = _names(event.get("given"))  # NPC -> stranger
        received = _names(event.get("received"))  # stranger -> NPC
        if ok:
            if given and received:
                memory = f"I traded my {given} for the stranger's {received}."
            elif received:
                memory = f"The stranger gave me {received}."
            else:
                memory = f"I gave the stranger {given}."
            turn = f"Trade done: {who} gave {given or 'nothing'} and got {received or 'nothing'}."
            importance = 5
        elif event.get("reason") == "rejected":
            memory, turn, importance = "I turned down a trade the stranger offered.", f"{who} turned the trade down.", 2
        else:
            memory = f"A trade with the stranger fell through: {FAILURES.get(event.get('reason'), 'something changed')}."
            turn = f"The trade did not happen: {FAILURES.get(event.get('reason'), 'something changed')}."
            importance = 3
    else:
        return 0
    store.add_turn(npc.uid, player_key, ts=ts, speaker="system", text=turn)
    return store.add_memory("personal", npc.uid, ts=ts, kind=f"action_{action}", text=memory,
                            importance=importance, player_key=player_key)


def apply_event(store: MemoryStore, event: Any, ts: int, world: str | None = None) -> int:
    """Records what the event means to the NPC and its squad (and, for a killing, its faction
    in this save: world). Returns memories written."""
    if not isinstance(event, dict):
        return 0
    npc = _npc(event)
    if npc is None:
        return 0
    store.upsert_npc(npc, ts)
    by = event.get("by") if isinstance(event.get("by"), dict) else {}
    by_player = by.get("kind") == "player" and isinstance(by.get("key"), str)
    player_key = by.get("key") if by_player else None
    who = npc.name or "one of us"
    written = 0
    kind = event.get("kind")

    if kind == "npc_hit":
        if by_player:
            store.shift_mood(npc.uid, player_key, HIT_TRUST, HIT_FEAR, ts)
            if not _recent(store, "personal", npc.uid, "hit_by_player", ts - REPEAT_WINDOW_MS):
                weapon = weapon_name(event.get("weapon"))
                written += store.add_memory("personal", npc.uid, ts=ts, kind="hit_by_player", importance=7,
                                            player_key=player_key,
                                            text=f"The stranger hit me{' with a ' + weapon if weapon else ''}.")
                written += store.add_memory("squad", npc.group_id, ts=ts, kind="hit_by_player", importance=5,
                                            player_key=player_key, text=f"The stranger attacked {who}.")
        elif by.get("kind") == "npc":
            if not _recent(store, "personal", npc.uid, "hit_by_npc", ts - REPEAT_WINDOW_MS):
                written += store.add_memory("personal", npc.uid, ts=ts, kind="hit_by_npc", importance=4,
                                            text="Another survivor attacked me.")
    elif kind == "npc_action" and by_player:
        written += _apply_action(store, npc, player_key, event, ts)
    elif kind == "npc_died":
        if by_player:
            written += store.add_memory("squad", npc.group_id, ts=ts, kind="killed_by_player", importance=9,
                                        player_key=player_key, text=f"The stranger killed {who}.")
            written += store.add_memory("faction", faction_key(npc.faction_id, world), ts=ts, kind="killed_by_player",
                                        importance=6,
                                        player_key=player_key, text=f"The stranger killed {who}, one of our people.")
        elif by.get("kind") == "zombie":
            written += store.add_memory("squad", npc.group_id, ts=ts, kind="killed_by_zombie", importance=6,
                                        text=f"{who[:1].upper() + who[1:]} was killed by the dead.")
        else:
            written += store.add_memory("squad", npc.group_id, ts=ts, kind="died", importance=6,
                                        text=f"We lost {who}.")
    return written
