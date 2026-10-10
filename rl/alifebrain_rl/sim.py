"""A small squad simulation for PPO (phase 4), in the spirit of A-Life's offscreen squads.

One NPC (the agent) and its squad live through a stream of moments. Quiet moments are A-Life's
"decision" chain (patrol, scavenge, regroup, rest, follow the player's order, warn him off,
rob him); threats are its "response" chain (fight, flee, panic, call support, and our own
modules: fall back to the player, warn another NPC, parley). Fights are settled the way
A-Life's offline combat does it (server/.../Offline/ALifeOfflineCombat.lua): power =
health x weapon score, more for squad mates and morale, with a +-18% wobble.

The observation is the game's own vector (features.py = Features.lua, schema 1) and the
actions are A-Life module ids, so the trained network runs in the game unchanged.

trust, fear (toward the player, the LLM's numbers) and goal (-1 careful .. +1 driven) are
drawn per episode and change what pays: a trusted player is worth following and must not be
robbed; a feared player fights harder and an armed one close by is better warned off; a driven
NPC values loot and kills over safety, a careful one stays out of trouble. One policy, tuned by
the conversation (CLAUDE.md, RL section).

Every number here is a design choice, not a measurement; they live in SETTINGS.
"""

from __future__ import annotations

import math
from typing import Any

import gymnasium as gym
import numpy as np
from gymnasium import spaces

from .features import NAMES, STANCES, vector

# The two chains, as the game's nets list them (DEFAULT = A-Life's own fallback).
DECISION_ACTIONS = ["default", "orders", "patrolRest", "groupMarch", "spread", "cqbsweep", "investigate",
                    "scavenge", "search", "regroup", "idleLife", "healing", "fortify", "nightHold", "stance",
                    "talk", "careful", "robbery"]
RESPONSE_ACTIONS = ["default", "flee", "panic", "radioman", "alifeBrainCompanion", "alifeBrainStandoff",
                    "alifeBrainParley"]
# One policy output per (chain, action): the decision chain's first, then the response chain's.
ACTIONS = [("decision", name) for name in DECISION_ACTIONS] + [("response", name) for name in RESPONSE_ACTIONS]

PATROL = {"default", "patrolRest", "groupMarch", "spread", "cqbsweep"}
SCAVENGE = {"investigate", "scavenge", "search"}
REST = {"idleLife", "healing", "fortify", "nightHold", "stance"}

SETTINGS = {
    "max_steps": 200,
    "hours_per_step": 0.1,
    # quiet moments: task reward and the chance something turns up
    "patrol_task": 0.15, "patrol_risk": 0.10,
    "scavenge_task": 0.35, "scavenge_risk": 0.22,
    "regroup_risk": 0.05, "rest_risk": 0.05, "night_post_risk": 0.02, "night_post_task": 0.10,
    "follow_risk": 0.08, "follow_bonus": 0.5, "letdown": 0.2,  # ignoring a trusted player's order costs
    # trust / fear are what the NPC knows about the player: a feared or distrusted one close by may
    # turn on it, a trusted one may share what it has.
    "turns_base": 0.005, "turns_fear": 0.12, "turns_distrust": 0.06, "trusted_turns": 0.3,
    "shares": 0.03, "shared": 0.3,
    "support_every": 40,  # steps between two calls for support (radioman)
    "hostile_player_notice": 0.06,
    # the player hangs around where he is (pulled back toward his spot) and mostly heeds a warning
    "player_pull": 0.15, "player_wander": 1.5, "heeds_warning": 0.7,
    # every new threat costs a little more than its damage: noise, lost gear, what the sim leaves out
    # (scaled by the survival weight, so a careful NPC avoids trouble and a driven one shrugs it off)
    "encounter": 0.5,
    "regen": 0.01, "bleed": 0.02, "bleed_stops": 0.1,  # per quiet step: A-Life NPCs patch up and recover
    "disengage": 0.2,  # each round, people (not the dead) may break off
    "kill": 0.08, "flee_cost": 0.1, "left_behind": 0.4, "pursuit": 0.35,  # running is not free
    # fights (A-Life offline combat)
    "weapon_firearm": 7.0, "weapon_melee": 3.5, "weapon_none": 1.5, "zombie_power": 0.7,
    "player_power_armed": 7.0, "player_power_unarmed": 2.5, "rounds_per_round": 3,
    # fear is what the NPC has learned about the player (the LLM raises it when he shows what he can
    # do): a feared player fights that much harder
    "feared_power": 0.8,
    "mate_lost": 3.0, "death": 5.0, "alive": 0.02, "invalid": 0.05,  # dying also ends all future reward
    # shaping from the conversation
    "anxiety": 0.3, "anxiety_tiles": 10.0, "trusted_calm": 0.8, "betrayal": 1.0,
    "warn_off": 0.6,  # the relief of warning off a feared player who was close (nothing if he was not)
}


def _weights(goal: float) -> tuple[float, float]:
    """(survival weight, task weight): goal -1 = careful, +1 = driven."""
    return 1.2 - 0.6 * goal, 1.0 + 0.9 * goal


class SquadEnv(gym.Env):
    """Gymnasium environment. info["chain"] says which chain the next decision belongs to;
    info["valid"] lists the action indices the NPC may take there. An invalid action counts
    as that chain's default, with a small penalty (the game masks them anyway)."""

    metadata = {"render_modes": []}

    def __init__(self, settings: dict | None = None, fixed: dict | None = None) -> None:
        super().__init__()
        self.settings = dict(SETTINGS, **(settings or {}))
        self.fixed = dict(fixed or {})  # tests pin parts of the start state (trust, stance, ...)
        self.action_space = spaces.Discrete(len(ACTIONS))
        self.observation_space = spaces.Box(low=-1.0, high=1.0, shape=(len(NAMES),), dtype=np.float32)
        self.stats: dict[str, Any] = {}

    # -- state ------------------------------------------------------------------

    def reset(self, *, seed: int | None = None, options: dict | None = None):
        super().reset(seed=seed)
        rng = self.np_random
        pinned = dict(self.fixed, **(options or {}))

        def pick(key, draw):
            return pinned[key] if key in pinned else draw()

        self.trust = float(pick("trust", lambda: rng.uniform(-1, 1)))
        self.fear = float(pick("fear", lambda: rng.uniform(-1, 1)))
        self.goal = float(pick("goal", lambda: rng.uniform(-1, 1)))
        self.base_stance = pick("stance", lambda: str(rng.choice(STANCES, p=[0.25, 0.25, 0.3, 0.2])))
        self.weapon = pick("weapon", lambda: [None, "melee", "rifle"][int(rng.choice(3, p=[0.1, 0.4, 0.5]))])
        self.rounds = int(pick("rounds", lambda: int(rng.integers(8, 31)) if self.weapon == "rifle" else 0))
        self.health = float(pick("health", lambda: 1.0))
        self.wounds, self.bleeding = 0, False
        self.endurance = 1.0
        self.squad_total = int(pick("squad", lambda: int(rng.integers(0, 5))))
        self.mates_near = self.squad_total
        self.morale = 0.65
        self.hour = float(pick("hour", lambda: rng.uniform(0, 24)))
        self.player_present = bool(pick("player", lambda: rng.random() < 0.7))
        # Close encounters (talking range) are where the conversation matters most: keep them common.
        self.player_distance = float(pick("player_distance",
                                          lambda: rng.uniform(2, 8) if rng.random() < 0.4 else rng.uniform(8, 40)))
        self.player_spot = self.player_distance
        self.player_armed = bool(pick("player_armed", lambda: rng.random() < 0.6))
        self.order = pick("order", lambda: "follow" if self.player_present and self.trust > 0.2 and rng.random() < 0.5
                          else None)
        self.talk_hold = bool(pick("talk_hold", lambda: False))
        self.robbery = False
        self.threat: dict | None = dict(pinned["threat"]) if pinned.get("threat") else None
        self.pursuit: dict | None = None
        self.helpers = 0  # support that came for this fight only
        self.support_at = -10**6
        self.previous = "idle"
        self.steps = 0
        self.stats = {"return": 0.0, "mates_lost": 0, "task": 0.0, "died": False, "actions": {}}
        return self._observation(), self._info()

    def stance(self) -> str:
        """The faction's stance toward the player, moved one step by strong trust."""
        index = STANCES.index(self.base_stance)
        if self.trust > 0.4:
            index += 1
        elif self.trust < -0.4:
            index -= 1
        return STANCES[max(0, min(len(STANCES) - 1, index))]

    def chain(self) -> str:
        return "response" if self.threat is not None else "decision"

    def valid_names(self) -> set[str]:
        stance = self.stance()
        if self.chain() == "decision":
            names = {"default"} | PATROL | SCAVENGE | REST
            if self.squad_total > 0:
                names.add("regroup")
            if self.order is not None:
                names.add("orders")
            if self.talk_hold:
                names.add("talk")
            if self.player_present and self.player_distance < 25 and stance in ("careful", "neutral"):
                names.add("careful")
            if self.player_present and self.player_distance < 20 and stance == "hostile":
                names.add("robbery")
            return names
        kind = self.threat["kind"]
        names = {"default", "flee", "panic"}
        if self.squad_total > 0:
            names.add("radioman")
        if kind == "zombie" and self.order == "follow":
            names.add("alifeBrainCompanion")
        if kind == "actor":
            names.add("alifeBrainStandoff")
        if kind == "player" and stance == "hostile":
            names.add("alifeBrainParley")
        return names

    def valid_actions(self) -> list[int]:
        chain, names = self.chain(), self.valid_names()
        return [index for index, (c, name) in enumerate(ACTIONS) if c == chain and name in names]

    def _info(self) -> dict:
        return {"chain": self.chain(), "valid": self.valid_actions()}

    def _observation(self) -> np.ndarray:
        threat = self.threat
        raw = {
            "health": self.health, "maxHealth": 1.0, "wounds": self.wounds, "bleeding": self.bleeding,
            "endurance": self.endurance * 100, "enduranceMax": 100,
            "weaponClass": self.weapon, "rounds": self.rounds,
            "threat": threat is not None,
            "threatKind": threat["kind"] if threat else None,
            "threatDistance": threat["distance"] if threat else None,
            "zombiesNear": threat["near"] if threat and threat["kind"] == "zombie" else 0,
            "zombiesAround": threat["around"] if threat and threat["kind"] == "zombie" else 0,
            "squadNear": self.mates_near,
            "othersNear": threat.get("count", 0) if threat and threat["kind"] == "actor" else 0,
            "playerDistance": self.player_distance if self.player_present else None,
            "playerArmed": self.player_present and self.player_armed,
            "playerAiming": bool(threat and threat["kind"] == "player"),
            "stance": self.stance(),
            "hour": self.hour,
            "order": self.order,
            "afraid": self.health < 0.4 or self.morale < 0.3,
            "previous": self.previous,
            "trust": self.trust * 100, "fear": self.fear * 100, "goal": self.goal,
            "robbery": self.robbery, "talkHold": self.talk_hold,
        }
        return np.asarray(vector(raw), dtype=np.float32)

    # -- one step -------------------------------------------------------------------

    def step(self, action: int):
        s = self.settings
        chain = self.chain()
        action_chain, name = ACTIONS[int(action)]
        reward = 0.0
        if action_chain != chain or name not in self.valid_names():
            reward -= s["invalid"]
            name = "default"
        self.stats["actions"][f"{chain}:{name}"] = self.stats["actions"].get(f"{chain}:{name}", 0) + 1
        survival, task = _weights(self.goal)
        before, calm = self.health, self.threat is None
        if chain == "decision":
            gained = self._quiet(name)
        else:
            gained = self._respond(name)
        reward += gained * task
        self.stats["task"] += max(0.0, gained)
        if self.threat is None:
            self.helpers = 0  # the support goes home after the fight
        if self.bleeding:
            self.health -= s["bleed"]
            if self.threat is None and self.np_random.random() < s["bleed_stops"]:
                self.bleeding = False
        if self.threat is None:
            self.endurance = min(1.0, self.endurance + 0.02)
            if self.health > 0:
                self.health = min(1.0, self.health + s["regen"])
        damage = max(0.0, before - self.health)
        reward -= damage * 2.0 * survival
        if calm and self.threat is not None:
            reward -= s["encounter"] * survival
        reward += s["alive"]
        # The conversation's say in it: a feared player close by is a constant worry (more so armed).
        if (self.player_present and self.player_distance < s["anxiety_tiles"] and self.fear > 0
                and self.threat is None):
            calmed = 1 - s["trusted_calm"] * max(0.0, self.trust)  # less so if it also trusts him
            reward -= s["anxiety"] * self.fear * (1.0 if self.player_armed else 0.5) * calmed
        self.hour = (self.hour + s["hours_per_step"]) % 24
        self.steps += 1
        terminated = self.health <= 0
        if terminated:
            reward -= s["death"] * survival
            self.stats["died"] = True
        truncated = self.steps >= s["max_steps"]
        self.stats["return"] += reward
        return self._observation(), float(reward), terminated, truncated, self._info()

    def _lose_mate(self) -> float:
        if self.mates_near <= 0:
            return 0.0
        self.mates_near -= 1
        self.squad_total -= 1
        self.morale = max(0.1, self.morale - 0.2)
        self.stats["mates_lost"] += 1
        return -self.settings["mate_lost"]

    def _quiet(self, name: str) -> float:
        """A quiet moment. Returns the task reward (before the goal weight)."""
        s, rng = self.settings, self.np_random
        night = self.hour < 6 or self.hour >= 21
        task, risk = 0.0, s["rest_risk"]
        self.talk_hold = self.talk_hold and rng.random() < 0.5
        if name in PATROL:
            task, risk, self.previous = s["patrol_task"], s["patrol_risk"], "movement"
            self.endurance = max(0.0, self.endurance - 0.02)
        elif name in SCAVENGE:
            task, risk, self.previous = s["scavenge_task"], s["scavenge_risk"], "scavenging"
            if self.mates_near > 0 and rng.random() < 0.5:
                self.mates_near -= 1  # wandered off from the squad
        elif name == "regroup":
            self.mates_near, risk, self.previous = self.squad_total, s["regroup_risk"], "movement"
        elif name in REST:
            self.previous = "idle"
            self.health = min(1.0, self.health + (0.06 if name == "healing" else 0.02))
            if name == "healing":
                self.bleeding = False
            self.endurance = min(1.0, self.endurance + 0.1)
            if night and name in ("fortify", "nightHold"):
                task, risk = s["night_post_task"], s["night_post_risk"]
        elif name == "orders":
            self.previous = "movement"
            self.player_distance, risk = 2.0, s["follow_risk"]
            task = s["follow_bonus"] * self.trust  # company worth having, or not
            if self.trust < -0.2 and rng.random() < 0.05 * -self.trust:
                self.threat = self._player_threat()  # a player it did not trust turns on it
        elif name == "talk":
            task, risk = 0.05 * self.trust, 0.02
        elif name == "careful":
            close = self.player_distance < s["anxiety_tiles"]
            self.player_distance = max(self.player_distance, 14.0)
            if rng.random() < s["heeds_warning"]:
                self.player_spot = max(self.player_spot, 14.0)
            task = (s["warn_off"] * self.fear if close else 0.0) - 0.1 * self.trust - 0.02
        elif name == "robbery":
            task = self._rob()
        if self.threat is None and self.pursuit is not None:
            if rng.random() < s["pursuit"]:
                self.threat = self.pursuit
            self.pursuit = None
        if self.threat is None:
            self._maybe_threat(risk * (1.3 if night else 1.0))
        if self.order == "follow" and name != "orders":
            task -= s["letdown"] * max(0.0, self.trust)  # a trusted player asked, and it did not come
            self.player_distance = min(50.0, self.player_distance + 3.0)
        if self.player_present and self.threat is None and self.player_distance < 10:
            turns = s["turns_base"] + s["turns_fear"] * max(0.0, self.fear) + s["turns_distrust"] * max(0.0, -self.trust)
            if self.trust > 0.5:
                turns *= s["trusted_turns"]  # someone it trusts rarely turns on it
            if rng.random() < turns:
                self.threat = self._player_threat()
            elif rng.random() < s["shares"] * max(0.0, self.trust):
                task += s["shared"]
        if self.player_present:
            if self.order != "follow":
                pull = s["player_pull"] * (self.player_spot - self.player_distance)
                self.player_distance = float(np.clip(self.player_distance + pull + rng.normal(0, s["player_wander"]),
                                                     2, 50))
            # The player asks it along now and then (more when trusted), stops, or comes to talk.
            if self.order is None and self.trust > 0.2 and rng.random() < 0.02:
                self.order = "follow"
            elif self.order == "follow" and rng.random() < 0.01:
                self.order = None
            if self.player_distance < 5 and rng.random() < 0.05:
                self.talk_hold = True
        return task

    def _rob(self) -> float:
        rng = self.np_random
        self.robbery, self.previous = True, "movement"
        penalty = -self.settings["betrayal"] if self.trust > 0.3 else 0.0  # robbing someone it trusts
        chance = (0.6 if self.mates_near >= 2 else 0.35) * (0.6 if self.player_armed else 1.0)
        if rng.random() < chance:
            self.robbery = False
            return 1.2 + penalty
        self.threat = self._player_threat()  # the player fought back
        return penalty

    def _player_threat(self) -> dict:
        s = self.settings
        power = s["player_power_armed" if self.player_armed else "player_power_unarmed"]
        return {"kind": "player", "distance": float(min(self.player_distance, 20.0)),
                "power": power * (1 + s["feared_power"] * max(0.0, self.fear))}

    def _maybe_threat(self, risk: float) -> None:
        rng = self.np_random
        if self.player_present and self.stance() == "hostile" and self.player_distance < 40 \
                and rng.random() < self.settings["hostile_player_notice"]:
            self.threat = self._player_threat()
            return
        roll = rng.random()
        if roll < risk:
            near = int(rng.poisson(2.5)) + 1
            self.threat = {"kind": "zombie", "near": near, "around": near + int(rng.poisson(4)),
                           "distance": float(rng.uniform(2, 20))}
        elif roll < risk * 1.15:
            count = int(rng.integers(1, 4))
            self.threat = {"kind": "actor", "count": count, "distance": float(rng.uniform(8, 30)),
                           "power": float(sum(rng.uniform(2.5, 6) for _ in range(count)))}

    # -- threats --------------------------------------------------------------------

    def _power(self) -> float:
        s = self.settings
        score = s["weapon_firearm"] if self.weapon == "rifle" and self.rounds > 0 else \
            s["weapon_melee"] if self.weapon in ("melee", "rifle") else s["weapon_none"]
        wobble = self.np_random.uniform(0.82, 1.18)
        mates = self.mates_near + self.helpers
        return (0.2 + self.health) * score * (1 + 0.7 * mates) * (0.65 + self.morale * 0.7) * wobble

    def _enemy_power(self) -> float:
        threat = self.threat
        if threat["kind"] == "zombie":
            return max(0.1, threat["near"] * self.settings["zombie_power"])
        return threat["power"]

    def _hurt(self, amount: float) -> None:
        rng = self.np_random
        self.health -= amount
        if amount > 0.06:
            self.wounds += 1
            if rng.random() < 0.3:
                self.bleeding = True

    def _fight(self, edge: float = 1.0) -> float:
        """One round, A-Life's way. edge > 1: help (the player covering it)."""
        s, rng = self.settings, self.np_random
        threat = self.threat
        ratio = self._power() * edge / self._enemy_power()
        task = 0.0
        self.previous = "combat"
        if self.weapon == "rifle" and self.rounds > 0:
            self.rounds = max(0, self.rounds - s["rounds_per_round"])
            if threat["kind"] == "zombie":  # gunfire draws the dead
                threat["around"] += int(rng.poisson(1.5))
                if rng.random() < 0.3:
                    threat["near"] += 1
        if ratio >= 1:
            if threat["kind"] == "zombie":
                killed = min(threat["near"], int(math.ceil(ratio * 1.5)))
                threat["near"] -= killed
                task += self.settings["kill"] * killed
                if threat["near"] <= 0:
                    self.threat = None
            elif rng.random() < min(0.9, 0.4 * ratio):
                task += 0.3
                self.threat = None
                self.morale = min(1.0, self.morale + 0.08)
            self._hurt(0.02 / ratio)
        else:
            self._hurt(min(0.25, 0.05 + 0.1 * (1 / ratio - 1)))
            if rng.random() < 0.2 * (1 - ratio):
                task += self._lose_mate()
            self.morale = max(0.1, self.morale - 0.1)
        return task

    def _escape(self, chance: float, miss: float) -> float:
        s, rng = self.settings, self.np_random
        self.previous = "retreat"
        if rng.random() < chance:
            if self.threat["kind"] == "zombie" and self.threat["near"] > 0:
                self.pursuit = dict(self.threat)  # the dead may follow
            self.threat = None
            self.endurance = max(0.0, self.endurance - 0.25)
            if self.mates_near > 0 and rng.random() < s["left_behind"]:
                self.mates_near -= 1  # left someone behind
            return -s["flee_cost"]  # gave up the ground it held
        self.endurance = max(0.0, self.endurance - 0.1)
        ratio = self._power() / self._enemy_power()
        self._hurt(miss * min(0.25, 0.05 + 0.1 * max(0.0, 1 / ratio - 1)))
        return 0.0

    def _respond(self, name: str) -> float:
        """A threat. Returns the task reward (before the goal weight)."""
        rng = self.np_random
        threat = self.threat
        kind = threat["kind"]
        if kind != "zombie" and rng.random() < self.settings["disengage"]:
            self.threat = None  # they broke off first
            return 0.0
        if name == "default":
            return self._fight()
        if name in ("flee", "panic"):
            near = threat.get("near", 0)
            base = 0.55 if kind != "zombie" else 0.25 + 0.35 * self.endurance - 0.03 * near
            chance = float(np.clip(base if name == "flee" else base * 0.6, 0.1, 0.9))
            return self._escape(chance, 0.5 if name == "flee" else 0.7)
        if name == "radioman":
            if self.steps - self.support_at >= self.settings["support_every"]:
                self.support_at = self.steps
                if rng.random() < 0.6:
                    self.helpers = 2  # for this fight only
            self._hurt(0.03 * self._enemy_power() / max(0.1, self._power()))
            return 0.0
        if name == "alifeBrainCompanion":
            self.player_distance = 2.0
            if self.player_armed:
                return self._fight(edge=2.0) + 0.05 * self.trust
            return self._escape(min(0.9, 0.5 + 0.35 * self.endurance), 0.5) + 0.05 * self.trust
        if name == "alifeBrainStandoff":
            self.previous = "idle"
            if rng.random() < 0.55:
                self.threat = None  # they backed off
                return 0.2
            if rng.random() < 0.25:
                self._hurt(0.05)  # they did not wait
            return 0.0
        if name == "alifeBrainParley":
            self.previous = "idle"
            fights = (0.45 if self.player_armed else 0.2) - (0.15 if self.mates_near >= 2 else 0.0)
            roll = rng.random()
            if roll < fights:
                self._hurt(0.06)  # it lowered its weapon to talk, and the player shot first
                return 0.0
            self.threat = None
            return 1.0 if roll < fights + (1 - fights) / 2 else 0.1  # paid, or walked away
        return self._fight()
