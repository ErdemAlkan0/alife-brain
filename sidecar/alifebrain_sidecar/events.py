"""Append-only log of game events (memory input now, RL training data later)."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


class EventStore:
    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.count = 0

    def append(self, *, ts: int, received_ts: int, session: str, request_id: str, event: Any) -> None:
        record = {"ts": ts, "receivedTs": received_ts, "session": session, "id": request_id, "event": event}
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
        self.count += 1
