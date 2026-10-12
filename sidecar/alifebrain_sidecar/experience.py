"""Turns game events from EventLog.lua into NPC memories and mood shifts."""

from __future__ import annotations

import re
from typing import Any

from .memory import MemoryStore, Npc, faction_key

HIT_TRUST, HIT_FEAR = -10, 8
# A hit while the dead are right around the NPC (EventLog: zombiesNear): most likely meant for
# them, e.g. shotgun spread (play test, 2026-10-11: guards at -11 trust from one such shot).
ACCIDENT_TRUST, ACCIDENT_FEAR = -3, 2
# Deeds build trust too, not only words (play test, 2026-10-11: "I saved you" got "prove it",
# a fair trade left trust at -1): killing the dead beside an NPC, a gift, a fair swap.
HELP_TRUST, HELP_FEAR = 3, -1
GIFT_TRUST, TRADE_TRUST = 6, 2
REPEAT_WINDOW_MS = 60_000
HELP_MEMORY_WINDOW_MS = 300_000
# A crew that robbed the player (Robberies.lua, A-Life's ModuleRobbery): a stranger who gave in
# is a little less frightening and a little more trusted; one who fought back, the opposite.
GAVE_IN_TRUST, GAVE_IN_FEAR = 1, -2
FOUGHT_TRUST, FOUGHT_FEAR = -3, 3
ROBBERY_WHY = {
    "fled": "ran for it", "drew_weapon": "drew a weapon", "armed": "would not drop their weapon",
    "no_hands": "would not put their hands up", "shouted": "shouted for help", "aimed_at_crew": "aimed at us",
    "attacked_crew": "attacked us", "hostile_surrender": "would not give in",
}


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
    "combat": "was in the middle of a fight",
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
            if received:  # a gift, or a fair swap: the stranger kept their side
                store.shift_mood(npc.uid, player_key, GIFT_TRUST if not given else TRADE_TRUST, 0, ts)
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


def _apply_robbery(store: MemoryStore, leader: Npc, player_key: str, event: dict, ts: int) -> int:
    """robbed_player: every crew member remembers how robbing the stranger went."""
    crew = [_npc({"npc": member}) for member in event.get("crew") or [] if isinstance(member, dict)]
    crew = [member for member in crew if member is not None][:6] or [leader]
    outcome = event.get("outcome") if isinstance(event.get("outcome"), str) else ""
    taken = _names(event.get("taken"))
    crew_of = f"{leader.name}'s crew" if leader.name else "The crew"
    if outcome == "released":
        if taken:
            text, turn = f"We robbed the stranger and took their {taken}.", f"{crew_of} robbed the stranger and took {taken}."
        else:
            text = "We robbed the stranger, but they had nothing worth taking."
            turn = f"{crew_of} robbed the stranger, who had nothing worth taking."
        importance, trust, fear = (6 if taken else 4), GAVE_IN_TRUST, GAVE_IN_FEAR
    elif outcome.startswith("execute:"):
        why = ROBBERY_WHY.get(outcome.split(":", 1)[1], "would not give in")
        text = f"We tried to rob the stranger; they {why}, so we opened fire."
        turn = f"{crew_of} tried to rob the stranger and opened fire: the stranger {why}."
        importance, trust, fear = 7, FOUGHT_TRUST, FOUGHT_FEAR
    else:
        text, turn = "Our robbery of the stranger came to nothing.", f"{crew_of} tried to rob the stranger; it came to nothing."
        importance, trust, fear = 3, 0, 0
    written = 0
    for member in crew:
        store.upsert_npc(member, ts)
        if trust or fear:
            store.shift_mood(member.uid, player_key, trust, fear, ts)
        written += store.add_memory("personal", member.uid, ts=ts, kind="robbed_player", importance=importance,
                                    player_key=player_key, text=text)
    written += store.add_memory("squad", leader.group_id, ts=ts, kind="robbed_player", importance=importance,
                                player_key=player_key, text=text)
    store.add_turn(leader.uid, player_key, ts=ts, speaker="system", text=turn)
    return written


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
        near = event.get("zombiesNear")
        accident = by_player and isinstance(near, int) and not isinstance(near, bool) and near > 0
        if accident:
            store.shift_mood(npc.uid, player_key, ACCIDENT_TRUST, ACCIDENT_FEAR, ts)
            if not _recent(store, "personal", npc.uid, "hit_by_player_by_accident", ts - REPEAT_WINDOW_MS):
                written += store.add_memory("personal", npc.uid, ts=ts, kind="hit_by_player_by_accident",
                                            importance=4, player_key=player_key,
                                            text="The stranger hit me by accident while we were fighting the dead.")
        elif by_player:
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
    elif kind == "robbed_player" and by_player:
        written += _apply_robbery(store, npc, player_key, event, ts)
    elif kind == "player_helped" and by_player:
        kills = event.get("kills")
        kills = max(1, min(20, kills)) if isinstance(kills, int) and not isinstance(kills, bool) else 1
        store.shift_mood(npc.uid, player_key, HELP_TRUST + (1 if kills >= 3 else 0), HELP_FEAR, ts)
        if not _recent(store, "personal", npc.uid, "helped_by_player", ts - HELP_MEMORY_WINDOW_MS):
            dead = "one of the dead" if kills == 1 else f"{kills} of the dead"
            written += store.add_memory("personal", npc.uid, ts=ts, kind="helped_by_player", importance=6,
                                        player_key=player_key, text=f"The stranger killed {dead} right next to me.")
            if not _recent(store, "squad", npc.group_id, "helped_by_player", ts - HELP_MEMORY_WINDOW_MS):
                written += store.add_memory("squad", npc.group_id, ts=ts, kind="helped_by_player", importance=4,
                                            player_key=player_key, text=f"The stranger fought the dead beside {who}.")
    elif kind == "npc_died":
        if by_player:
            written += store.add_memory("squad", npc.group_id, ts=ts, kind="killed_by_player", importance=9,
                                        player_key=player_key, text=f"The stranger killed {who}.")
            # A-Life reuses names in every squad: the rest of the faction hears of "a" Deputy Rowe
            # of another group (recall leaves this out for the dead NPC's own squad).
            written += store.add_memory("faction", faction_key(npc.faction_id, world), ts=ts, kind="killed_by_player",
                                        importance=6, player_key=player_key,
                                        text=f"The stranger killed {who}, one of our people in another group.")
        elif by.get("kind") == "zombie":
            written += store.add_memory("squad", npc.group_id, ts=ts, kind="killed_by_zombie", importance=6,
                                        text=f"{who[:1].upper() + who[1:]} was killed by the dead.")
        else:
            # Say who did it: "We lost Deputy Rowe." alone let the LLM blame the player (play test,
            # 2026-10-11).
            written += store.add_memory("squad", npc.group_id, ts=ts, kind="died", importance=6,
                                        text=_loss(store, who, by))
    return written


def _loss(store: MemoryStore, who: str, by: dict) -> str:
    if by.get("kind") != "npc":
        return f"We lost {who}; nobody saw who did it."
    known = store.npc(by["uid"]) if isinstance(by.get("uid"), str) else None
    killer = by.get("name") if isinstance(by.get("name"), str) and by.get("name") else (known.name if known else None)
    if not killer:
        return f"Another survivor killed {who}, not the stranger."
    return f"{killer} killed {who}, not the stranger."
