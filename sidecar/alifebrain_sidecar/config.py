"""Sidecar settings: <data dir>/config.json plus environment overrides.

API keys are never stored in the file; only the *name* of the environment variable that
holds a key is. The Player2 client id is a public game identifier, so it may live in the
file (or in ALIFEBRAIN_PLAYER2_CLIENT_ID).
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

PROVIDERS = ("player2", "ollama", "openai", "fake")


@dataclass
class Player2Settings:
    base_url: str = "http://localhost:4315/v1"
    client_id: str = ""
    health_interval_s: int = 60


@dataclass
class OllamaSettings:
    base_url: str = "http://localhost:11434/v1"
    model: str = "llama3.1:8b"


@dataclass
class OpenAISettings:
    base_url: str = "https://api.openai.com/v1"
    model: str = "gpt-4o-mini"
    api_key_env: str = "OPENAI_API_KEY"


@dataclass
class DialogueSettings:
    # Player2 over 130 replies (2026-10-11/12): median 11 s, 95% within 20 s, slowest 32 s; 30 s gave up on 3%.
    # Slower on some evenings: 37 and 43 s for the first reply of a conversation (2026-10-12). The game is
    # paused while the window is open, so waiting longer costs little.
    timeout_s: float = 60.0
    max_tokens: int = 220
    temperature: float = 0.8
    history_turns: int = 6
    memories: int = 6


@dataclass
class MemorySettings:
    summarize: bool = True  # old memories are rewritten into a short summary (one LLM call each)
    summary_after: int = 14  # a layer (one NPC, squad or faction) with more unsummarized memories gets one
    keep_recent: int = 6  # its newest memories stay as they are
    summary_every_s: int = 60  # at most one summary this often, and only while no reply is being written
    summary_retry_s: int = 600  # a layer whose summary failed waits this long
    summary_max_tokens: int = 220


@dataclass
class Settings:
    provider: str = "player2"
    player2: Player2Settings = field(default_factory=Player2Settings)
    ollama: OllamaSettings = field(default_factory=OllamaSettings)
    openai: OpenAISettings = field(default_factory=OpenAISettings)
    dialogue: DialogueSettings = field(default_factory=DialogueSettings)
    memory: MemorySettings = field(default_factory=MemorySettings)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


# Defaults that were written into config.json on first run and changed since: a file still
# holding the old value gets the new one ((section, key) -> old value).
OLD_DEFAULTS = {("dialogue", "timeout_s"): 30.0}


def _upgrade(settings: Settings, values: dict[str, Any]) -> None:
    for (section, key), old in OLD_DEFAULTS.items():
        written = values.get(section)
        if isinstance(written, dict) and written.get(key) == old:
            new = getattr(type(getattr(settings, section))(), key)
            setattr(getattr(settings, section), key, new)
            log.info("%s.%s %s was the old default; using %s", section, key, old, new)


def _merge(target: Any, values: dict[str, Any]) -> None:
    for key, value in values.items():
        if not hasattr(target, key):
            log.warning("unknown setting %s ignored", key)
            continue
        current = getattr(target, key)
        if hasattr(current, "__dataclass_fields__") and isinstance(value, dict):
            _merge(current, value)
        else:
            setattr(target, key, value)


def load_settings(path: Path, environ: dict[str, str] | None = None) -> Settings:
    """Reads config.json (writing a default one on first run) and applies env overrides."""
    environ = os.environ if environ is None else environ
    settings = Settings()
    path = Path(path)
    if path.exists():
        values = json.loads(path.read_text(encoding="utf-8"))
        _merge(settings, values)
        _upgrade(settings, values)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(settings.to_dict(), indent=2) + "\n", encoding="utf-8")
        log.info("wrote default settings to %s", path)

    if environ.get("ALIFEBRAIN_PROVIDER"):
        settings.provider = environ["ALIFEBRAIN_PROVIDER"]
    if environ.get("ALIFEBRAIN_PLAYER2_CLIENT_ID"):
        settings.player2.client_id = environ["ALIFEBRAIN_PLAYER2_CLIENT_ID"]
    if settings.provider not in PROVIDERS:
        raise ValueError(f"unknown provider {settings.provider!r}; choose one of {', '.join(PROVIDERS)}")
    return settings
