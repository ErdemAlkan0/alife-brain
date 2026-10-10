"""NPC memory in SQLite, keyed by A-Life uid. Three layers: personal (uid), squad
(A-Life groupId) and faction (factionId). Only the main sidecar thread touches it."""

from __future__ import annotations

import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path

SCOPES = ("personal", "squad", "faction")
MOOD_LIMIT = 100
# The NPC's drive (the policy's goal input, -100 lie low .. 100 go out for supplies and risks):
# one per NPC, stirred by conversations and settling back to 0 (the game uses the same half-life).
GOAL_LIMIT = 100
GOAL_HALF_LIFE_MS = 30 * 60 * 1000

_SCHEMA = """
CREATE TABLE IF NOT EXISTS npcs (
    uid TEXT PRIMARY KEY,
    name TEXT, faction_id TEXT, faction_name TEXT, group_id TEXT, profile_id TEXT,
    first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS moods (
    uid TEXT NOT NULL, player_key TEXT NOT NULL,
    trust INTEGER NOT NULL DEFAULT 0, fear INTEGER NOT NULL DEFAULT 0, updated INTEGER NOT NULL,
    PRIMARY KEY (uid, player_key)
);
CREATE TABLE IF NOT EXISTS drives (
    uid TEXT PRIMARY KEY, goal REAL NOT NULL DEFAULT 0, updated INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS memories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scope TEXT NOT NULL, scope_key TEXT NOT NULL, player_key TEXT,
    ts INTEGER NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL, importance INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS memories_by_scope ON memories (scope, scope_key, ts);
CREATE TABLE IF NOT EXISTS turns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uid TEXT NOT NULL, player_key TEXT NOT NULL, ts INTEGER NOT NULL, speaker TEXT NOT NULL, text TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS turns_by_pair ON turns (uid, player_key, ts);
"""

_WORD = re.compile(r"[^\W\d_]{3,}", re.UNICODE)


def _words(text: str) -> set[str]:
    return {word.lower() for word in _WORD.findall(text or "")}


def settle(goal: float, elapsed_ms: int) -> float:
    """A drive halves every GOAL_HALF_LIFE_MS (Dialogue.goalNow in the game does the same)."""
    return goal * 0.5 ** (max(0, elapsed_ms) / GOAL_HALF_LIFE_MS)


@dataclass(frozen=True)
class Npc:
    uid: str
    name: str | None = None
    faction_id: str | None = None
    faction_name: str | None = None
    group_id: str | None = None
    profile_id: str | None = None


@dataclass(frozen=True)
class Memory:
    scope: str
    ts: int
    kind: str
    text: str
    importance: int


class MemoryStore:
    def __init__(self, path: Path | str) -> None:
        if str(path) != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(path))
        self.db.executescript(_SCHEMA)
        self.db.commit()

    def close(self) -> None:
        self.db.close()

    # -- NPCs and moods ---------------------------------------------------------

    def upsert_npc(self, npc: Npc, ts: int) -> None:
        self.db.execute(
            """INSERT INTO npcs (uid, name, faction_id, faction_name, group_id, profile_id, first_seen, last_seen)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(uid) DO UPDATE SET
                 name = COALESCE(excluded.name, name), faction_id = COALESCE(excluded.faction_id, faction_id),
                 faction_name = COALESCE(excluded.faction_name, faction_name),
                 group_id = COALESCE(excluded.group_id, group_id),
                 profile_id = COALESCE(excluded.profile_id, profile_id), last_seen = excluded.last_seen""",
            (npc.uid, npc.name, npc.faction_id, npc.faction_name, npc.group_id, npc.profile_id, ts, ts),
        )
        self.db.commit()

    def npc(self, uid: str) -> Npc | None:
        row = self.db.execute(
            "SELECT uid, name, faction_id, faction_name, group_id, profile_id FROM npcs WHERE uid = ?", (uid,)
        ).fetchone()
        return Npc(*row) if row else None

    def mood(self, uid: str, player_key: str) -> tuple[int, int]:
        row = self.db.execute("SELECT trust, fear FROM moods WHERE uid = ? AND player_key = ?",
                              (uid, player_key)).fetchone()
        return (row[0], row[1]) if row else (0, 0)

    def shift_mood(self, uid: str, player_key: str, trust_delta: int, fear_delta: int, ts: int) -> tuple[int, int]:
        trust, fear = self.mood(uid, player_key)
        trust = max(-MOOD_LIMIT, min(MOOD_LIMIT, trust + int(trust_delta)))
        fear = max(-MOOD_LIMIT, min(MOOD_LIMIT, fear + int(fear_delta)))
        self.db.execute(
            """INSERT INTO moods (uid, player_key, trust, fear, updated) VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(uid, player_key) DO UPDATE SET trust = excluded.trust, fear = excluded.fear,
                 updated = excluded.updated""",
            (uid, player_key, trust, fear, ts),
        )
        self.db.commit()
        return trust, fear

    def _drive(self, uid: str, now: int) -> float:
        row = self.db.execute("SELECT goal, updated FROM drives WHERE uid = ?", (uid,)).fetchone()
        if not row:
            return 0.0
        return settle(row[0], now - row[1])

    def drive(self, uid: str, now: int) -> int:
        """The NPC's goal now (-100..100), settled toward 0 since it was last stirred."""
        return round(self._drive(uid, now))

    def shift_drive(self, uid: str, delta: int, ts: int) -> int:
        goal = max(-GOAL_LIMIT, min(GOAL_LIMIT, self._drive(uid, ts) + int(delta)))
        self.db.execute(
            """INSERT INTO drives (uid, goal, updated) VALUES (?, ?, ?)
               ON CONFLICT(uid) DO UPDATE SET goal = excluded.goal, updated = excluded.updated""",
            (uid, goal, ts),
        )
        self.db.commit()
        return round(goal)

    def moods(self, uids: list[str], player_key: str, now: int) -> list[dict]:
        """trust / fear toward the player and goal for each NPC that has any of them stored."""
        out = []
        for uid in uids:
            mood = self.db.execute("SELECT trust, fear FROM moods WHERE uid = ? AND player_key = ?",
                                   (uid, player_key)).fetchone()
            drive = self.db.execute("SELECT 1 FROM drives WHERE uid = ?", (uid,)).fetchone()
            if mood is None and drive is None:
                continue
            trust, fear = mood if mood else (0, 0)
            out.append({"uid": uid, "trust": trust, "fear": fear, "goal": self.drive(uid, now)})
        return out

    # -- memories ---------------------------------------------------------------

    def add_memory(self, scope: str, scope_key: str | None, *, ts: int, kind: str, text: str,
                   importance: int, player_key: str | None = None) -> bool:
        if scope not in SCOPES:
            raise ValueError(f"unknown scope {scope}")
        text = (text or "").strip()
        if not scope_key or not text:
            return False
        importance = max(1, min(10, int(importance)))
        self.db.execute(
            "INSERT INTO memories (scope, scope_key, player_key, ts, kind, text, importance) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (scope, scope_key, player_key, ts, kind, text[:300], importance),
        )
        self.db.commit()
        return True

    def recall(self, npc: Npc, *, query: str = "", now: int, limit: int = 6) -> list[Memory]:
        """Most useful memories across the three layers.

        Score = importance + recency (+4 when fresh, halved after one real-time day)
        + 2 per word shared with the query; personal memories rank above squad, squad above
        faction.
        """
        keys = [("personal", npc.uid), ("squad", npc.group_id), ("faction", npc.faction_id)]
        layer_bonus = {"personal": 2, "squad": 1, "faction": 0}
        query_words = _words(query)
        scored: list[tuple[float, Memory]] = []
        for scope, key in keys:
            if not key:
                continue
            rows = self.db.execute(
                "SELECT ts, kind, text, importance FROM memories WHERE scope = ? AND scope_key = ? "
                "ORDER BY ts DESC LIMIT 200", (scope, key)).fetchall()
            for ts, kind, text, importance in rows:
                age_hours = max(0.0, (now - ts) / 3_600_000)
                recency = 4.0 / (1.0 + age_hours / 24.0)
                overlap = len(query_words & _words(text))
                score = importance + recency + 2 * overlap + layer_bonus[scope]
                scored.append((score, Memory(scope, ts, kind, text, importance)))
        scored.sort(key=lambda item: (item[0], item[1].ts), reverse=True)
        chosen = [memory for _, memory in scored[:limit]]
        chosen.sort(key=lambda memory: memory.ts)
        return chosen

    def count_memories(self, scope: str, scope_key: str) -> int:
        return self.db.execute("SELECT COUNT(*) FROM memories WHERE scope = ? AND scope_key = ?",
                               (scope, scope_key)).fetchone()[0]

    # -- conversation turns -----------------------------------------------------

    def add_turn(self, uid: str, player_key: str, *, ts: int, speaker: str, text: str) -> None:
        self.db.execute("INSERT INTO turns (uid, player_key, ts, speaker, text) VALUES (?, ?, ?, ?, ?)",
                        (uid, player_key, ts, speaker, text[:400]))
        self.db.commit()

    def recent_turns(self, uid: str, player_key: str, limit: int = 6) -> list[tuple[str, str]]:
        return [(speaker, text) for speaker, text, _ in self.recent_turns_with_time(uid, player_key, limit)]

    def recent_turns_with_time(self, uid: str, player_key: str, limit: int = 6) -> list[tuple[str, str, int]]:
        """Oldest first. speaker is "player", "npc" or "system" (game-side outcomes)."""
        rows = self.db.execute(
            "SELECT speaker, text, ts FROM turns WHERE uid = ? AND player_key = ? ORDER BY ts DESC, id DESC LIMIT ?",
            (uid, player_key, limit)).fetchall()
        return list(reversed(rows))
