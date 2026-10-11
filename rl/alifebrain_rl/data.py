"""Loads the behavior cloning dataset the sidecar writes (sidecar/alifebrain_sidecar/dataset.py):
schema-<n>.json (feature names) and decisions-<date>.jsonl (one A-Life decision per line)."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

import numpy as np

DEFAULT = "default"  # A-Life's own fallback when no module of the chain answered


def default_dir() -> Path:
    local = os.environ.get("LOCALAPPDATA")
    base = Path(local) if local else Path.home() / ".local" / "share"
    return base / "ALifeBrain" / "dataset"


@dataclass
class Dataset:
    dispatch: str
    schema: int
    names: list[str]
    actions: list[str]  # DEFAULT first, then module ids
    obs: np.ndarray  # (N, F) float32
    labels: np.ndarray  # (N,) int64, index into actions
    masks: np.ndarray  # (N, A) bool: what that NPC was allowed to do
    groups: np.ndarray  # (N,) int64: one id per NPC, for an honest train/validation split
    ts: np.ndarray  # (N,) int64

    def __len__(self) -> int:
        return len(self.labels)

    def counts(self) -> dict[str, int]:
        found = np.bincount(self.labels, minlength=len(self.actions))
        return {action: int(found[index]) for index, action in enumerate(self.actions) if found[index]}


def schemas(directory: Path) -> dict[int, list[str]]:
    found = {}
    for path in Path(directory).glob("schema-*.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            found[int(data["schema"])] = [str(name) for name in data["names"]]
        except (ValueError, KeyError, TypeError, OSError, json.JSONDecodeError):
            continue
    return found


def rows(directory: Path) -> Iterator[dict]:
    for path in sorted(Path(directory).glob("decisions-*.jsonl")):
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue  # a line cut short by a crash
                if isinstance(row, dict):
                    yield row


def load(directory: Path, dispatch: str, schema: int | None = None,
         exclude: frozenset[str] = frozenset()) -> Dataset | None:
    """Every decision A-Life made in one chain ("decision" or "response") for one schema (the
    newest by default), leaving out decisions labelled with an exclude action (e.g. data
    recorded while one of our modules misbehaved) and those the policy picked under policy
    control ("chosen": not A-Life's choice); None when there is none."""
    known = schemas(directory)
    if not known:
        return None
    schema = max(known) if schema is None else schema
    if schema not in known:
        return None
    names = known[schema]
    kept = [row for row in rows(directory)
            if row.get("schema") == schema and row.get("dispatch") == dispatch
            and isinstance(row.get("obs"), list) and len(row["obs"]) == len(names) and isinstance(row.get("label"), str)
            and row["label"] not in exclude and row.get("chosen") is not True]
    if not kept:
        return None
    modules = set()
    for row in kept:
        modules.add(row["label"])
        modules.update(entry for entry in row.get("allowed") or [] if isinstance(entry, str))
    modules.discard(DEFAULT)
    actions = [DEFAULT] + sorted(modules)
    index = {action: position for position, action in enumerate(actions)}

    obs = np.asarray([row["obs"] for row in kept], dtype=np.float32)
    labels = np.asarray([index[row["label"]] for row in kept], dtype=np.int64)
    masks = np.zeros((len(kept), len(actions)), dtype=bool)
    masks[:, index[DEFAULT]] = True
    uids: dict[str, int] = {}
    groups = np.zeros(len(kept), dtype=np.int64)
    ts = np.zeros(len(kept), dtype=np.int64)
    for position, row in enumerate(kept):
        for entry in row.get("allowed") or []:
            if entry in index:
                masks[position, index[entry]] = True
        masks[position, labels[position]] = True  # what A-Life did was allowed, whatever the list said
        groups[position] = uids.setdefault(str(row.get("uid") or f"row{position}"), len(uids))
        ts[position] = int(row.get("ts") or 0)
    return Dataset(dispatch, schema, names, actions, obs, labels, masks, groups, ts)
