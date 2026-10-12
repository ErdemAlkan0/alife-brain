"""Memory summaries: old memories of one layer (an NPC's own, its squad's or its faction's)
are rewritten by the LLM into one short summary, so a long-lived NPC still knows its past
while the prompt carries only that summary and a few fresh memories (CLAUDE.md, memory).
The sidecar runs it while no reply is being written (app.Sidecar._maybe_summarize)."""

from __future__ import annotations

import json
import re

from .dialogue import _shorten
from .memory import SUMMARY_LIMIT, SummaryCandidate

LAYERS = {"personal": ("I", "your own memories"), "squad": ("we", "your group's memories"),
          "faction": ("we", "what your people know")}
SUMMARY_MARKER = "You keep the memories of"


class InvalidSummary(ValueError):
    pass


def build_summary_messages(candidate: SummaryCandidate, who: str) -> list[dict[str, str]]:
    pronoun, what = LAYERS.get(candidate.scope, LAYERS["personal"])
    system = (
        f"{SUMMARY_MARKER} {who}, a survivor in Knox County, Kentucky, during the 1993 zombie outbreak. Rewrite "
        f"{what} below into one short summary, in the first person (\"{pronoun}\"), at most three sentences and "
        f"{SUMMARY_LIMIT} characters. Keep who did what to whom and how it ended, keep every name exactly as written, "
        "and keep what \"the stranger\" did. Drop small talk and repeats. Never add anything that is not written "
        "below. Reply with the summary only."
    )
    lines = []
    if candidate.previous_text:
        lines.append(f"Earlier summary: {candidate.previous_text}")
    lines.append("Memories, oldest first:\n" + "\n".join(f"- {text}" for text in candidate.texts))
    return [{"role": "system", "content": system}, {"role": "user", "content": "\n\n".join(lines)}]


def parse_summary(text: str) -> str:
    """The model's summary as one clean line, at most SUMMARY_LIMIT characters."""
    text = (text or "").strip()
    fenced = re.search(r"```(?:\w+)?\s*(.*?)```", text, re.DOTALL)
    if fenced:
        text = fenced.group(1).strip()
    if text.startswith("{"):
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            data = None
        if isinstance(data, dict):
            text = next((str(data[key]) for key in ("summary", "say", "text") if isinstance(data.get(key), str)), "")
    text = re.sub(r"^(summary|özet)\s*:\s*", "", text, flags=re.IGNORECASE)
    text = re.sub(r"\s+", " ", text).strip().strip("\"'").strip()
    if len(text) < 10:
        raise InvalidSummary("empty_summary")
    return _shorten(text, SUMMARY_LIMIT)
