"""Dialogue: validate the game's request, build the prompt, validate the LLM's JSON reply.

The LLM never controls the game directly: its output is reduced to a fixed schema here,
deltas are clamped, and intents outside the whitelist become "none". The game re-checks.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any

from .memory import Memory, Npc

INTENTS = ("none", "give", "follow", "stay", "leave", "trade", "warn", "attack", "rob", "give_info")
# The game carries these out (Dialogue.lua); the rest are only recorded for now.
ACTIONS = ("give", "follow", "stay", "leave", "trade")
ITEMS = ("water", "food", "medicine")
MAX_SAY = 200
MAX_NOTE = 200
MAX_INPUT = 300
DELTA_LIMIT = 10

STRANGER_SAYS = "The stranger says:"

TEMPERAMENTS = {
    "fresh": "new to this world; shaken, still hoping things get better",
    "seasoned": "hardened by weeks of surviving; practical and slow to trust",
    "veteran": "a trained professional; calm, controlled, used to giving orders",
    "predator": "someone who sees other people as prey or tools",
}
STANCES = {
    "friendly": "you consider the stranger an ally",
    "neutral": "the stranger is someone you neither trust nor fear yet",
    "careful": "you are wary of the stranger and want them to keep their distance",
    "hostile": "the stranger is an enemy",
}
ACTIVITIES = {
    "combat": "you are in the middle of a fight",
    "retreat": "you are falling back",
    "movement": "you are on the move",
    "scavenging": "you are searching for supplies",
    "idle": "you are standing guard",
    "recovering": "you are catching your breath after a fight",
}


class BadRequest(ValueError):
    """The game sent a dialogue request we cannot use."""


class InvalidReply(ValueError):
    """The LLM's output does not follow the schema."""


@dataclass(frozen=True)
class DialogueRequest:
    text: str
    player_key: str
    npc: Npc
    role_label: str | None = None
    temperament: str | None = None
    sex: str | None = None
    stance: str = "neutral"
    activity: str | None = None
    wounded: bool = False
    facts: dict[str, Any] = field(default_factory=dict)
    weapon: str | None = None
    town: str | None = None
    hour: int | None = None
    day: int | None = None
    inventory: dict[str, int] = field(default_factory=dict)
    inventory_items: dict[str, list[str]] = field(default_factory=dict)
    following: bool = False
    # Parley (Parley.lua): a hostile NPC stopped the stranger before shooting. opening = the NPC
    # speaks first; text is then a narration, not the stranger's words.
    standoff: bool = False
    opening: bool = False
    language: str | None = None  # the game's language code, e.g. "TR"
    # Trade window: everything the NPC could trade, what the stranger could trade (the NPC may
    # ask for it), and what is on the table right now.
    tradeable: tuple["TradeLine", ...] = ()
    player_tradeable: tuple["TradeLine", ...] = ()
    trade_open: bool = False
    trade_offer: tuple["TradeLine", ...] = ()  # the stranger puts these down
    trade_ask: tuple["TradeLine", ...] = ()  # the stranger wants these from the NPC


@dataclass(frozen=True)
class TradeLine:
    name: str
    count: int = 1

    def text(self) -> str:
        return f"{self.count}x {self.name}" if self.count > 1 else self.name


@dataclass(frozen=True)
class DialogueReply:
    say: str
    memory_note: str
    trust_delta: int
    fear_delta: int
    intent: str
    item: str | None = None
    # Trade answer: "accept" (the table swaps now), "reject", or "counter" with trade_offer
    # (names of things the NPC carries that it puts on the table instead) and trade_wants
    # (names of the stranger's things it wants back; the game puts them on the table too).
    trade_decision: str | None = None
    trade_offer: tuple[str, ...] = ()
    trade_wants: tuple[str, ...] = ()
    # True when a "give" was turned into a trade proposal because it was part of a deal.
    deal_guard: bool = False
    # What the model actually wrote, for the log when we had to reinterpret it.
    raw_intent: str | None = None
    raw_item: str | None = None


TRADE_DECISIONS = ("accept", "reject", "counter")
TRADE_ALIASES = {"yes": "accept", "agree": "accept", "deal": "accept", "accepted": "accept", "no": "reject",
                 "decline": "reject", "refuse": "reject", "rejected": "reject", "offer": "counter",
                 "propose": "counter", "counteroffer": "counter", "counter_offer": "counter"}
MAX_TRADE_LINES = 10
MAX_TRADEABLE = 30
MAX_NPC_OFFER = 5


# Models often answer with a variant or with the item's own name instead of the category.
INTENT_ALIASES = {"give_item": "give", "hand_over": "give", "handover": "give", "drop": "give", "share": "give",
                  "offer": "give", "come": "follow", "join": "follow", "wait": "stay", "hold": "stay", "goodbye": "leave",
                  "bye": "leave"}
ITEM_ALIASES = {
    "water": ("water", "su", "drink", "bottle", "şişe"),
    "food": ("food", "yemek", "yiyecek", "snack", "chips", "cips", "can", "konserve", "bread", "ekmek"),
    "medicine": ("medicine", "med", "meds", "medkit", "medical", "bandage", "bandaj", "pill", "ilaç", "ilac",
                 "first aid", "ilk yardım", "disinfectant", "dezenfektan"),
}


def _text(value: Any, limit: int) -> str | None:
    if not isinstance(value, str):
        return None
    value = re.sub(r"[\x00-\x1f\x7f]+", " ", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value[:limit] or None


def _int(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return int(value)


def _inventory(value: Any) -> dict[str, int]:
    if not isinstance(value, dict):
        return {}
    counts = {}
    for item in ITEMS:
        count = _int(value.get(item))
        if count is not None:
            counts[item] = max(0, min(99, count))
    return counts


def _inventory_items(value: Any) -> dict[str, list[str]]:
    """Display names of the spare items (as the game shows them, possibly translated)."""
    if not isinstance(value, dict):
        return {}
    items = {}
    for item in ITEMS:
        names = value.get(item)
        if isinstance(names, list):
            cleaned = [name for name in (_text(entry, 40) for entry in names[:5]) if name]
            if cleaned:
                items[item] = cleaned
    return items


def _trade_lines(value: Any, limit: int) -> tuple[TradeLine, ...]:
    if not isinstance(value, list):
        return ()
    lines = []
    for entry in value[:limit]:
        if isinstance(entry, dict):
            name = _text(entry.get("name"), 60)
            if name:
                lines.append(TradeLine(name, max(1, min(99, _int(entry.get("count")) or 1))))
    return tuple(lines)


def _listing(lines: tuple[TradeLine, ...]) -> str:
    return ", ".join(line.text() for line in lines)


def _carrying(inventory: dict[str, int], items: dict[str, list[str]] | None = None) -> str:
    names = {"water": ("water bottle", "water bottles"), "food": ("food item", "food items"),
             "medicine": ("medical item", "medical items")}
    parts = []
    for item, count in inventory.items():
        if count <= 0:
            continue
        part = f"{count} {names[item][0] if count == 1 else names[item][1]}"
        if items and items.get(item):
            part += " (" + ", ".join(items[item]) + ")"
        parts.append(part)
    return ", ".join(parts) if parts else "nothing you could spare"


def parse_request(data: Any) -> DialogueRequest:
    if not isinstance(data, dict):
        raise BadRequest("data_not_object")
    npc_data, player = data.get("npc"), data.get("player")
    if not isinstance(npc_data, dict) or not isinstance(player, dict):
        raise BadRequest("npc_or_player_missing")
    uid = _text(npc_data.get("uid"), 64)
    player_key = _text(player.get("key"), 100)
    text = _text(data.get("text"), MAX_INPUT)
    if not uid or not player_key or not text:
        raise BadRequest("uid_player_or_text_missing")
    facts = data.get("facts") if isinstance(data.get("facts"), dict) else {}
    world = data.get("world") if isinstance(data.get("world"), dict) else {}
    trade = data.get("trade") if isinstance(data.get("trade"), dict) else None
    stance = _text(data.get("stance"), 20) or "neutral"
    return DialogueRequest(
        text=text,
        player_key=player_key,
        npc=Npc(
            uid=uid,
            name=_text(npc_data.get("name"), 80),
            faction_id=_text(npc_data.get("factionId"), 80),
            faction_name=_text(npc_data.get("factionName"), 80),
            group_id=_text(npc_data.get("groupId"), 120),
            profile_id=_text(npc_data.get("profileId"), 80),
        ),
        role_label=_text(npc_data.get("roleLabel"), 80),
        temperament=_text(npc_data.get("temperament"), 20),
        sex=_text(npc_data.get("sex"), 2),
        stance=stance if stance in STANCES else "neutral",
        activity=_text(npc_data.get("behaviorState"), 30),
        wounded=(_int(npc_data.get("wounds")) or 0) > 0,
        facts={key: value for key, value in facts.items() if isinstance(key, str) and value is True},
        weapon=_text(player.get("weapon"), 60),
        town=_text(world.get("town"), 60),
        hour=_int(world.get("hour")),
        day=_int(world.get("day")),
        inventory=_inventory(npc_data.get("inventory")),
        inventory_items=_inventory_items(npc_data.get("inventoryItems")),
        following=npc_data.get("following") is True,
        standoff=isinstance(data.get("standoff"), dict),
        opening=isinstance(data.get("standoff"), dict) and data["standoff"].get("opening") is True,
        language=_text(world.get("language"), 8),
        tradeable=_trade_lines(npc_data.get("tradeable"), MAX_TRADEABLE),
        player_tradeable=_trade_lines(player.get("tradeable"), MAX_TRADEABLE),
        trade_open=trade is not None,
        trade_offer=_trade_lines(trade.get("playerOffer"), MAX_TRADE_LINES) if trade else (),
        trade_ask=_trade_lines(trade.get("npcSide"), MAX_TRADE_LINES) if trade else (),
    )


LANGUAGES = {"TR": "Turkish", "EN": "English", "DE": "German", "FR": "French", "ES": "Spanish", "IT": "Italian",
             "RU": "Russian", "PL": "Polish", "PT": "Portuguese", "PTBR": "Brazilian Portuguese", "CN": "Chinese",
             "JP": "Japanese", "KO": "Korean", "UA": "Ukrainian", "CS": "Czech", "NL": "Dutch", "HU": "Hungarian"}

STANDOFF_RULES = (
    "- STANDOFF: you and your people are hostile to the stranger. You have them covered and stopped them before "
    "shooting. Say what you want, short and menacing: demand tribute from what they carry (trade: decision "
    "counter, npc_wants = their things you want, npc_offer empty; the game takes it when they hand it over), or "
    "order them away. intent attack = you open fire now and the talk is over. Your patience is short: the first "
    "time they refuse, give them one last warning; if they refuse again, threaten you, insult you, lie badly or "
    "stall, attack. Look at the conversation so far: if you already warned them once, do not warn again. intent "
    "leave = you let them go; use it once they paid or clearly back off. You are not their friend and you do not "
    "hand anything out."
)


def _sentence(text: str) -> str:
    return text[:1].upper() + text[1:] + "."


def _situation(request: DialogueRequest) -> list[str]:
    lines = []
    if request.activity in ACTIVITIES:
        lines.append(_sentence(ACTIVITIES[request.activity]))
    if request.wounded:
        lines.append("You are wounded.")
    if request.facts.get("player_armed"):
        weapon = f" ({request.weapon})" if request.weapon else ""
        lines.append(f"The stranger is holding a weapon{weapon}.")
    if request.facts.get("recent_zombie_contact"):
        lines.append("You fought the dead a few minutes ago.")
    if request.facts.get("recent_human_contact"):
        lines.append("You had a run-in with other people a few minutes ago.")
    when = []
    if request.hour is not None:
        when.append(f"it is {request.hour:02d}:00")
    if request.day is not None:
        when.append(f"day {request.day + 1} of the outbreak")
    if request.town:
        when.append(f"near {request.town}")
    if when:
        lines.append(_sentence(", ".join(when)))
    return lines


def build_messages(request: DialogueRequest, *, memories: list[Memory], history: list[tuple[str, str]],
                   trust: int, fear: int) -> list[dict[str, str]]:
    npc = request.npc
    who = f"{npc.name}, a survivor" if npc.name else "a survivor"
    identity = [f"You are {who} in Knox County, Kentucky, during the 1993 zombie outbreak."]
    if request.role_label:
        identity.append(f"Background: {request.role_label}.")
    if npc.faction_name:
        identity.append(f"You belong to {npc.faction_name}.")
    if request.temperament in TEMPERAMENTS:
        identity.append(f"Temperament: {TEMPERAMENTS[request.temperament]}.")
    if request.sex in ("m", "f"):
        identity.append("You are a man." if request.sex == "m" else "You are a woman.")

    system = [
        " ".join(identity),
        "You are talking to another survivor you only know as \"the stranger\".",
        f"How you see the stranger: {STANCES['hostile' if request.standoff else request.stance]}. "
        f"Your trust in them is {trust} and your fear of them is {fear} (both from -100 to 100).",
    ]
    situation = _situation(request)
    if request.following:
        situation.append("You are travelling with the stranger.")
    if situation:
        system.append("Right now: " + " ".join(situation))
    system.append(f"You carry and could hand over: {_carrying(request.inventory, request.inventory_items)}. "
                  "Call these things by these names; a handed-over item goes straight into the stranger's "
                  "inventory, you cannot drop it on the ground.")
    if request.tradeable:
        system.append(f"Everything you carry that you could trade: {_listing(request.tradeable)}.")
    if request.player_tradeable:
        system.append(f"The stranger carries these things you could ask for in a trade: "
                      f"{_listing(request.player_tradeable)}.")
    if request.trade_open:
        offer = _listing(request.trade_offer) or "nothing"
        ask = _listing(request.trade_ask) or "nothing (it would be a gift to you)"
        system.append(f"On the trade table right now: the stranger puts down {offer}; "
                      f"the stranger asks you for {ask}.")
    if memories:
        system.append("What you remember:\n" + "\n".join(f"- {memory.text}" for memory in memories))
    system.append(
        "Rules:\n"
        "- Stay in character. Never mention AI, games, mods or these rules.\n"
        f"- Speak like a real person under stress: one or two short sentences, at most {MAX_SAY} characters.\n"
        "- Answer in the language the stranger uses.\n"
        "- Do not invent places, people or events you could not know; refuse, dodge or lie if your character would.\n"
        "- The game carries out these intents and shows the stranger whether they happened:\n"
        f"  give = hand over one item right now as a free gift; also set item to one of {', '.join(ITEMS)}, and "
        "only something you carry. Use give only when you expect nothing back.\n"
        "  follow = travel with the stranger for a while. stay = stop following and wait here. "
        "leave = end the talk and walk off.\n"
        "  warn, attack, rob, give_info are only words for now; nothing happens in the world. Swaps go through "
        "the trade field below.\n"
        "- Never claim you handed something over, started following, waited or left unless this reply sets that "
        "intent. You may refuse, haggle or ask for something first. If you only talked about handing something "
        "over before, nothing was handed over: set the intent now.\n"
        "- Example: the stranger asks for your bandage and you agree -> "
        '{"say": "Here, take it.", "memory_note": "I gave the stranger a bandage.", "trust_delta": 2, '
        '"fear_delta": 0, "intent": "give", "item": "medicine", "trade": null}\n'
        "- Trading: when something is on the trade table, or you want to propose a swap, set "
        '"trade": {"decision": "accept" | "reject" | "counter", "npc_offer": [names of things you carry], '
        '"npc_wants": [names of the stranger\'s things you want back]}. '
        "accept = the swap on the table happens right now. counter = you put npc_offer on the table instead, "
        "ask for npc_wants, and the stranger may take the deal. reject = no deal. Judge the deal like your "
        'character would; you may simply accept a gift. Otherwise "trade": null.\n'
        "- Never hand anything over on a promise (\"give it to me and I'll pay you\", \"I'll bring it later\"). "
        "If you want something in return it is a trade, not give: counter with npc_offer and npc_wants. The game "
        "puts both sides on the table and swaps them at the same moment, only when the stranger's part is there, "
        "so nobody can walk off with yours. If the stranger asks for your things but puts nothing down, do not "
        "accept: counter with what you want.\n"
        "- Example: the stranger offers a bandage for your water -> "
        '{"say": "Water for that bandage. Fair.", "memory_note": "I agreed to swap my water for the stranger\'s '
        'bandage.", "trust_delta": 1, "fear_delta": 0, "intent": "trade", "item": null, "trade": '
        '{"decision": "counter", "npc_offer": ["Water Bottle"], "npc_wants": ["Bandage"]}}\n'
        "- Reply with exactly one JSON object and nothing else:\n"
        '{"say": "...", "memory_note": "...", "trust_delta": 0, "fear_delta": 0, "intent": "none", "item": null, '
        '"trade": null}\n'
        "  say: your spoken words.\n"
        "  memory_note: one short sentence worth remembering about this exchange, or \"\".\n"
        f"  trust_delta, fear_delta: integers from -{DELTA_LIMIT} to {DELTA_LIMIT}; how this exchange changes "
        "your trust in and fear of the stranger.\n"
        f"  intent: one of {', '.join(INTENTS)}. Use none unless you really mean to act.\n"
        "  item: only with intent give, otherwise null."
    )

    if request.standoff:
        system.append(STANDOFF_RULES.strip())

    user = []
    if history:
        speakers = {"player": "The stranger: ", "npc": "You: ", "system": "(What actually happened) "}
        lines = [speakers.get(speaker, "") + text for speaker, text in history]
        user.append("Conversation so far:\n" + "\n".join(lines))
    if request.opening:
        # The NPC speaks first; there is nothing from the stranger yet to copy the language from.
        language = LANGUAGES.get((request.language or "").upper())
        user.append(request.text + (f" Speak {language}." if language else ""))
    else:
        user.append(f"{STRANGER_SAYS} \"{request.text}\"")
    return [{"role": "system", "content": "\n\n".join(system)}, {"role": "user", "content": "\n\n".join(user)}]


def _extract_json(text: str) -> dict:
    candidates = [text.strip()]
    fenced = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL)
    if fenced:
        candidates.append(fenced.group(1).strip())
    start, end = text.find("{"), text.rfind("}")
    if 0 <= start < end:
        candidates.append(text[start:end + 1])
    for candidate in candidates:
        try:
            value = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    raise InvalidReply("not_json")


def _shorten(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    cut = text[:limit]
    for mark in (". ", "! ", "? "):
        position = cut.rfind(mark)
        if position >= limit // 2:
            return cut[:position + 1]
    space = cut.rfind(" ")
    return (cut[:space] if space >= limit // 2 else cut).rstrip(",;:") + "..."


def _delta(value: Any) -> int:
    if isinstance(value, str):
        try:
            value = float(value)
        except ValueError:
            return 0
    number = _int(value)
    if number is None:
        return 0
    return max(-DELTA_LIMIT, min(DELTA_LIMIT, number))


def resolve_item(raw: str | None, request: DialogueRequest | None = None) -> str | None:
    """Category for what the model asked to hand over: a category word, the display name of
    something the NPC carries, a common alias, or - when the NPC carries only one kind - that."""
    carried = [item for item in ITEMS if request is not None and request.inventory.get(item, 0) > 0]
    if raw:
        word = raw.strip().lower()
        if word in ITEMS:
            return word
        if request is not None and len(word) >= 3:
            for item, names in request.inventory_items.items():
                if any(word == name.lower() or word in name.lower() or name.lower() in word for name in names):
                    return item
        tokens = re.findall(r"\w+", word)
        for item, aliases in ITEM_ALIASES.items():
            for alias in aliases:
                if " " in alias:
                    found = alias in word
                else:
                    found = alias in tokens or (len(alias) >= 4 and any(token.startswith(alias) for token in tokens))
                if found:
                    return item
    if len(carried) == 1:
        return carried[0]
    return None


def resolve_trade_names(value: Any, request: DialogueRequest | None = None, *,
                        lines: tuple[TradeLine, ...] | None = None) -> tuple[str, ...]:
    """Names put on the table, matched to what really is there (the game checks again):
    the NPC's things by default, or the given lines (the stranger's things for npc_wants).
    Unknown names are dropped."""
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list):
        return ()
    if lines is None and request is not None:
        lines = request.tradeable
    known = [line.name for line in lines] if lines is not None else None
    chosen: list[str] = []
    for entry in value[:MAX_NPC_OFFER * 2]:
        if isinstance(entry, dict):
            entry = entry.get("name")
        name = _text(entry, 60)
        if not name:
            continue
        if known is not None:
            word = name.lower()
            match = next((k for k in known if k.lower() == word), None)
            if match is None and len(word) >= 3:
                match = next((k for k in known if word in k.lower() or k.lower() in word), None)
            name = match
        if name and name not in chosen:
            chosen.append(name)
        if len(chosen) >= MAX_NPC_OFFER:
            break
    return tuple(chosen)


def _wants(value: Any, request: DialogueRequest | None) -> tuple[str, ...]:
    """The stranger's things the NPC asks for. The game only lists them (player.tradeable)
    when the conversation window with its trade table is open, which fills them in."""
    if request is None:
        return ()
    return resolve_trade_names(value, request, lines=request.player_tradeable)


def _trade(data: dict, request: DialogueRequest | None) -> tuple[str | None, tuple[str, ...], tuple[str, ...]]:
    trade = data.get("trade")
    if not isinstance(trade, dict):
        return None, (), ()
    raw = _text(trade.get("decision"), 20)
    decision = raw.lower().replace(" ", "_") if raw else None
    decision = TRADE_ALIASES.get(decision, decision)
    offer = resolve_trade_names(trade.get("npc_offer"), request)
    wants = _wants(trade.get("npc_wants"), request)
    if decision not in TRADE_DECISIONS:
        decision = "counter" if offer or wants else None
    if decision == "accept" and request is not None and not request.trade_open:
        decision = "counter" if offer or wants else None  # nothing on the table to accept
    if decision == "accept" and wants and request is not None and request.trade_ask and not request.trade_offer:
        # "Yes, if you give me X": what the stranger asked for stays up, X joins the table.
        decision, offer = "counter", resolve_trade_names([line.name for line in request.trade_ask], request)
    if decision == "counter" and not offer and not wants and request is not None and not request.trade_open:
        decision = None
    if decision != "counter":
        return decision, (), ()
    return decision, offer, wants


# A gift that is really one half of a deal ("give me water and I'll give you a bandage") would
# let the stranger take it and never pay. Exchange words in either line, or a promise in the
# stranger's line, turn the give into a trade proposal on the table instead (the game swaps
# both sides at once). False alarms only cost a click; a missed one is still a capped gift.
EXCHANGE_WORDS = ("karşılı", "takas", "değiş tokuş", "değişelim", "değiştirelim", "değişir mi", "trade", "swap",
                  "exchange", "in return", "barter")
PROMISE_WORDS = ("verirsen", "veririm", "vereceğim", "vereyim", "öderim", "ödeyeceğim", "borç", "sonra getir",
                 "i'll give", "i will give", "i'll pay", "i will pay", "pay you", "owe you")


def is_deal(stranger_said: str, npc_said: str) -> bool:
    stranger, npc = stranger_said.casefold(), npc_said.casefold()
    if any(word in stranger or word in npc for word in EXCHANGE_WORDS):
        return True
    return any(word in stranger for word in PROMISE_WORDS)


def mentioned(lines: tuple[TradeLine, ...], text: str) -> tuple[str, ...]:
    """Names from lines that the text mentions (word starts, so Turkish endings still match:
    "bandajını" -> "Bandaj")."""
    tokens = re.findall(r"\w+", text.casefold())
    found = []
    for line in lines:
        parts = [part for part in re.findall(r"\w+", line.name.casefold()) if len(part) >= 4]
        if any(token.startswith(part[:max(4, len(part) - 2)]) for part in parts for token in tokens):
            found.append(line.name)
        if len(found) >= MAX_NPC_OFFER:
            break
    return tuple(found)


def _guard_deal(request: DialogueRequest | None, item: str,
                say: str) -> tuple[tuple[str, ...], tuple[str, ...]] | None:
    """For a give that is part of a deal: (npc_offer, npc_wants) of the trade proposal that
    replaces it, or None for a plain gift. An empty offer means the item cannot be named on
    the table: then nothing is handed over."""
    if request is None or not is_deal(request.text, say):
        return None
    names = request.inventory_items.get(item) or []
    offer = resolve_trade_names(names[:1], request)
    wants = tuple(name for name in mentioned(request.player_tradeable, f"{request.text} {say}") if name not in offer)
    return offer, wants


def parse_reply(text: str, request: DialogueRequest | None = None) -> DialogueReply:
    data = _extract_json(text or "")
    say = _text(data.get("say"), 2000)
    if not say:
        raise InvalidReply("missing_say")
    say = say.strip("\"' ")
    if not say:
        raise InvalidReply("missing_say")
    raw_intent = _text(data.get("intent"), 30)
    intent = raw_intent.lower().replace(" ", "_") if raw_intent else "none"
    intent = INTENT_ALIASES.get(intent, intent)
    if intent not in INTENTS:
        intent = "none"
    raw_item = _text(data.get("item"), 40)
    item = None
    if intent == "give":
        item = resolve_item(raw_item, request)
        if item is None:
            intent = "none"
    trade_decision, trade_offer, trade_wants = _trade(data, request)
    deal_guard = False
    if intent == "give" and trade_decision is None:
        deal = _guard_deal(request, item, say)
        if deal is not None:
            deal_guard = True
            if deal[0]:
                trade_decision, (trade_offer, trade_wants) = "counter", deal
            else:
                intent, item = "none", None
    if trade_decision is not None and intent in ("none", "give"):
        intent, item = "trade", None
    return DialogueReply(
        say=_shorten(say, MAX_SAY),
        memory_note=_shorten(_text(data.get("memory_note"), 2000) or "", MAX_NOTE),
        trust_delta=_delta(data.get("trust_delta")),
        fear_delta=_delta(data.get("fear_delta")),
        intent=intent,
        item=item,
        trade_decision=trade_decision,
        trade_offer=trade_offer,
        trade_wants=trade_wants,
        deal_guard=deal_guard,
        raw_intent=raw_intent,
        raw_item=raw_item,
    )
