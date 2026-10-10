"""LLM providers behind one OpenAI-compatible chat interface (stdlib HTTP only)."""

from __future__ import annotations

import json
import logging
import os
import socket
import time
import urllib.error
import urllib.request
from typing import Any

from .config import Settings

log = logging.getLogger(__name__)

Message = dict[str, str]


class LLMError(Exception):
    """Provider failure with a short code the game can log (e.g. "rate_limited")."""

    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail


class OpenAICompatibleProvider:
    name = "openai"

    def __init__(self, base_url: str, *, model: str | None = None, headers: dict[str, str] | None = None,
                 json_mode: bool = True, send_sampling: bool = True) -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.headers = {"Content-Type": "application/json", **(headers or {})}
        self.json_mode = json_mode
        self.send_sampling = send_sampling

    def _request(self, method: str, path: str, body: dict | None, timeout: float) -> Any:
        data = json.dumps(body).encode("utf-8") if body is not None else None
        request = urllib.request.Request(self.base_url + path, data=data, headers=self.headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read()[:300].decode("utf-8", "replace")
            if error.code == 429:
                raise LLMError("rate_limited", detail) from None
            if error.code in (401, 403):
                raise LLMError("unauthorized", detail) from None
            raise LLMError(f"http_{error.code}", detail) from None
        except (socket.timeout, TimeoutError):
            raise LLMError("timeout") from None
        except urllib.error.URLError as error:
            if isinstance(error.reason, (socket.timeout, TimeoutError)):
                raise LLMError("timeout") from None
            raise LLMError("unreachable", str(error.reason)) from None
        try:
            return json.loads(payload)
        except json.JSONDecodeError:
            raise LLMError("bad_response", payload[:200].decode("utf-8", "replace")) from None

    def chat(self, messages: list[Message], *, max_tokens: int, temperature: float, timeout: float) -> str:
        body: dict[str, Any] = {"messages": messages}
        if self.model:
            body["model"] = self.model
        if self.send_sampling:
            body["max_tokens"] = max_tokens
            body["temperature"] = temperature
        if self.json_mode:
            body["response_format"] = {"type": "json_object"}
        reply = self._request("POST", "/chat/completions", body, timeout)
        try:
            content = reply["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError):
            raise LLMError("bad_response", str(reply)[:200]) from None
        if not isinstance(content, str):
            raise LLMError("bad_response", "content is not text")
        return content


class Player2Provider(OpenAICompatibleProvider):
    """Player2 desktop app (http://localhost:4315/v1). The player logs in to the app; we
    only identify the game with its client id. The app picks the model, so we send just
    the messages and validate whatever JSON comes back."""

    name = "player2"

    def __init__(self, base_url: str, client_id: str) -> None:
        super().__init__(base_url, headers={"player2-game-key": client_id}, json_mode=False, send_sampling=False)
        self.client_id = client_id

    # Player2 now and then turns a request down at once ("user input rejected", HTTP 400) and
    # takes the very same request a moment later (seen with hostile standoff lines). One retry,
    # only when the refusal came back fast enough to leave time for it.
    RETRY_WITHIN_S = 5.0

    def chat(self, messages: list[Message], *, max_tokens: int, temperature: float, timeout: float) -> str:
        if not self.client_id:
            raise LLMError("player2_client_id_missing")
        started = time.monotonic()
        try:
            return super().chat(messages, max_tokens=max_tokens, temperature=temperature, timeout=timeout)
        except LLMError as error:
            spent = time.monotonic() - started
            if error.code != "http_400" or "rejected" not in error.detail or spent > self.RETRY_WITHIN_S:
                raise
            log.info("Player2 rejected the request (%s); retrying once", error.detail[:80])
            return super().chat(messages, max_tokens=max_tokens, temperature=temperature, timeout=max(5.0, timeout - spent))

    def health(self, timeout: float = 3.0) -> Any:
        return self._request("GET", "/health", None, timeout)


class FakeProvider:
    """Deterministic stand-in so the in-game flow can be tested without any LLM.
    Keywords trigger actions: water/su -> give water, food/yemek -> give food,
    follow/takip -> follow, wait/bekle -> stay, bye/hoşça -> leave. Trading: karşılığında /
    in exchange -> its first item for the stranger's first, anything on the table -> accept,
    teklif / offer -> its first item."""

    name = "fake"
    KEYWORDS = (
        (("water", "su "), "give", "water"),
        (("food", "yemek"), "give", "food"),
        (("follow", "takip"), "follow", None),
        (("wait", "bekle"), "stay", None),
        (("bye", "hoşça", "hosca"), "leave", None),
    )

    def chat(self, messages: list[Message], *, max_tokens: int, temperature: float, timeout: float) -> str:
        said = next((m["content"] for m in reversed(messages) if m["role"] == "user"), "")
        system = next((m["content"] for m in messages if m["role"] == "system"), "")
        heard = said.rsplit("The stranger says:", 1)[-1].strip().strip('"')
        intent, item, trade = "none", None, None
        lowered = heard.lower() + " "
        def first_of(marker: str) -> str | None:
            if marker not in system:
                return None
            first = system.split(marker, 1)[1].split(".", 1)[0].split(", ")[0]
            return first.split("x ", 1)[1] if first[:1].isdigit() and "x " in first else first

        mine, theirs = first_of("could trade: "), first_of("could ask for in a trade: ")
        if any(word in lowered for word in ("karşılı", "exchange")) and mine and theirs:
            intent, trade = "trade", {"decision": "counter", "npc_offer": [mine], "npc_wants": [theirs]}
        elif "On the trade table right now" in system:
            intent, trade = "trade", {"decision": "accept", "npc_offer": []}
        elif any(word in lowered for word in ("teklif", "offer")) and mine:
            intent, trade = "trade", {"decision": "counter", "npc_offer": [mine]}
        else:
            for words, action, thing in self.KEYWORDS:
                if any(word in lowered for word in words):
                    intent, item = action, thing
                    break
        return json.dumps({
            "say": f"(test) You said: {heard[:120]}" + (f" -> {intent} {item or ''}".rstrip() if intent != "none" else ""),
            "memory_note": f"The stranger said: {heard[:80]}",
            "trust_delta": 1,
            "fear_delta": 0,
            "intent": intent,
            "item": item,
            "trade": trade,
        })


def build_provider(settings: Settings, environ: dict[str, str] | None = None):
    environ = os.environ if environ is None else environ
    if settings.provider == "player2":
        return Player2Provider(settings.player2.base_url, settings.player2.client_id)
    if settings.provider == "ollama":
        return OpenAICompatibleProvider(settings.ollama.base_url, model=settings.ollama.model)
    if settings.provider == "openai":
        key = environ.get(settings.openai.api_key_env, "")
        if not key:
            raise LLMError("api_key_missing", f"set the {settings.openai.api_key_env} environment variable")
        return OpenAICompatibleProvider(settings.openai.base_url, model=settings.openai.model,
                                        headers={"Authorization": f"Bearer {key}"})
    if settings.provider == "fake":
        return FakeProvider()
    raise LLMError("unknown_provider", settings.provider)
