"""Behavior cloning data: A-Life's own decisions with what the NPC saw (DecisionLog.lua).

The game sends "decision_samples" events; each valid row becomes one JSON line in
<data dir>/dataset/decisions-<date>.jsonl, and the feature names of each schema go to
schema-<n>.json. rl/alifebrain_rl reads both. Rows that do not fit the schema are dropped.
"""

from __future__ import annotations

import json
import logging
import math
import re
import time
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

DISPATCHES = ("decision", "response")
MAX_ROWS = 64
MAX_FEATURES = 256
MAX_ALLOWED = 64
ID = re.compile(r"^[A-Za-z0-9_.:\-]{1,64}$")


def _id(value: Any) -> str | None:
    return value if isinstance(value, str) and ID.match(value) else None


def _vector(value: Any) -> list[float] | None:
    if not isinstance(value, list) or not 0 < len(value) <= MAX_FEATURES:
        return None
    out = []
    for number in value:
        if isinstance(number, bool) or not isinstance(number, (int, float)) or not math.isfinite(number):
            return None
        out.append(float(number))
    return out


class DatasetStore:
    def __init__(self, directory: Path, *, day=None) -> None:
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.day = day or (lambda: time.strftime("%Y-%m-%d"))
        self.names: dict[int, list[str]] = {}
        self.count = 0
        self.rejected = 0
        for path in self.directory.glob("schema-*.json"):
            try:
                schema = int(path.stem.split("-", 1)[1])
                names = json.loads(path.read_text(encoding="utf-8"))["names"]
            except (ValueError, KeyError, OSError, json.JSONDecodeError):
                continue
            if isinstance(names, list):
                self.names[schema] = names

    def _schema(self, schema: int, names: Any) -> None:
        if not isinstance(names, list) or not all(isinstance(name, str) for name in names) or not names:
            return
        known = self.names.get(schema)
        if known == names:
            return
        if known is not None:
            log.warning("dataset schema %d changed its feature names; keeping the first ones (bump SCHEMA in "
                        "Features.lua when features change)", schema)
            return
        self.names[schema] = names
        path = self.directory / f"schema-{schema}.json"
        path.write_text(json.dumps({"schema": schema, "names": names}, indent=1), encoding="utf-8")
        log.info("dataset schema %d: %d features", schema, len(names))

    def add_batch(self, event: dict, *, ts: int, session: str | None) -> int:
        """Stores the valid rows of one decision_samples event; returns how many."""
        schema = event.get("schema")
        if isinstance(schema, bool) or not isinstance(schema, int) or schema < 1:
            self.rejected += 1
            return 0
        self._schema(schema, event.get("names"))
        expected = len(self.names[schema]) if schema in self.names else None
        rows = event.get("rows") if isinstance(event.get("rows"), list) else []
        lines = []
        for row in rows[:MAX_ROWS]:
            record = self._row(row, schema, expected, ts, session)
            if record is None:
                self.rejected += 1
            else:
                lines.append(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
        if lines:
            path = self.directory / f"decisions-{self.day()}.jsonl"
            with path.open("a", encoding="utf-8") as handle:
                handle.write("\n".join(lines) + "\n")
            self.count += len(lines)
        return len(lines)

    @staticmethod
    def _row(row: Any, schema: int, expected: int | None, ts: int, session: str | None) -> dict | None:
        if not isinstance(row, dict):
            return None
        dispatch, label, obs = row.get("d"), _id(row.get("a")), _vector(row.get("o"))
        if dispatch not in DISPATCHES or label is None or obs is None:
            return None
        if expected is not None and len(obs) != expected:
            return None
        allowed = row.get("m") if isinstance(row.get("m"), list) else []
        allowed = [entry for entry in (_id(value) for value in allowed[:MAX_ALLOWED]) if entry]
        when = row.get("t")
        record = {
            "schema": schema,
            "session": session,
            "ts": when if isinstance(when, int) and not isinstance(when, bool) else ts,
            "dispatch": dispatch,
            "label": label,
            "obs": obs,
            "allowed": allowed,
        }
        for key, field in (("u", "uid"), ("f", "faction"), ("p", "profile"), ("pa", "policy")):
            value = _id(row.get(key))
            if value is not None:
                record[field] = value
        return record
