"""The game's observation vector (mod/.../ALifeBrain/Features.lua, schema 1), in Python, so the
simulation (sim.py) speaks exactly what the game feeds the policy. Keep the two in step: same
names, order, units and clamping. Changing either means a new SCHEMA on both sides."""

from __future__ import annotations

import math
from typing import Any

SCHEMA = 1

NAMES = [
    "health", "wounds", "bleeding", "downed", "endurance",
    "firearm", "melee", "rounds", "jammed",
    "threat", "threat_player", "threat_zombie", "threat_actor", "threat_distance",
    "zombies_near", "zombies_around", "squad_near", "others_near",
    "player_distance", "player_armed", "player_aiming",
    "stance_hostile", "stance_careful", "stance_neutral", "stance_friendly",
    "hour_sin", "hour_cos", "night",
    "order_follow", "order_hold", "order_patrol",
    "afraid",
    "was_idle", "was_movement", "was_combat", "was_retreat", "was_recovering", "was_scavenging",
    "trust", "fear", "goal",
    "robbery", "talk_hold",
]

STANCES = ("hostile", "careful", "neutral", "friendly")
ORDERS = ("follow", "hold", "patrol")
STATES = ("idle", "movement", "combat", "retreat", "recovering", "scavenging")


def _clamp(value: float, low: float, high: float) -> float:
    return low if value < low else high if value > high else value


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def _ratio(value: Any, scale: float) -> float:
    number = _number(value)
    return 0.0 if number is None else _clamp(number / scale, 0.0, 1.0)


def _flag(value: Any) -> float:
    return 1.0 if value is True else 0.0


def vector(raw: dict | None) -> list[float]:
    """Features.vector: plain values (all optional, same keys as Hooks.decisionObservation)
    -> len(NAMES) numbers in 0..1 or -1..1."""
    raw = raw if isinstance(raw, dict) else {}
    out: list[float] = []
    max_health = _number(raw.get("maxHealth")) or 1.0
    if max_health <= 0:
        max_health = 1.0
    health = _number(raw.get("health"))
    out.append(_clamp((max_health if health is None else health) / max_health, 0.0, 1.0))
    out.append(_ratio(raw.get("wounds"), 5))
    out.append(_flag(raw.get("bleeding")))
    out.append(_flag(raw.get("downed")))
    endurance_max = _number(raw.get("enduranceMax")) or 0.0
    endurance = _number(raw.get("endurance"))
    out.append(_clamp((endurance_max if endurance is None else endurance) / endurance_max, 0.0, 1.0)
               if endurance_max > 0 else 1.0)

    weapon = raw.get("weaponClass")
    out.append(1.0 if weapon in ("handgun", "rifle") else 0.0)
    out.append(1.0 if weapon in ("melee", "spear") else 0.0)
    out.append(_ratio(raw.get("rounds"), 30))
    out.append(_flag(raw.get("jammed")))

    threat = raw.get("threat") is True
    kind = raw.get("threatKind") if threat else None
    out.append(_flag(threat))
    out += [1.0 if kind == name else 0.0 for name in ("player", "zombie", "actor")]
    out.append(_ratio(raw.get("threatDistance"), 30) if threat and raw.get("threatDistance") is not None else 1.0)

    out.append(_ratio(raw.get("zombiesNear"), 10))
    out.append(_ratio(raw.get("zombiesAround"), 25))
    out.append(_ratio(raw.get("squadNear"), 6))
    out.append(_ratio(raw.get("othersNear"), 6))

    out.append(_ratio(raw.get("playerDistance"), 50) if raw.get("playerDistance") is not None else 1.0)
    out.append(_flag(raw.get("playerArmed")))
    out.append(_flag(raw.get("playerAiming")))
    out += [1.0 if raw.get("stance") == stance else 0.0 for stance in STANCES]

    hour = _number(raw.get("hour"))
    if hour is not None:
        angle = hour / 24 * 2 * math.pi
        out += [math.sin(angle), math.cos(angle), 1.0 if (hour < 6 or hour >= 21) else 0.0]
    else:
        out += [0.0, 0.0, 0.0]

    out += [1.0 if raw.get("order") == order else 0.0 for order in ORDERS]
    out.append(_flag(raw.get("afraid")))
    out += [1.0 if raw.get("previous") == state else 0.0 for state in STATES]

    out.append(_clamp((_number(raw.get("trust")) or 0.0) / 100, -1.0, 1.0))
    out.append(_clamp((_number(raw.get("fear")) or 0.0) / 100, -1.0, 1.0))
    out.append(_clamp(_number(raw.get("goal")) or 0.0, -1.0, 1.0))

    out.append(_flag(raw.get("robbery")))
    out.append(_flag(raw.get("talkHold")))
    return out
