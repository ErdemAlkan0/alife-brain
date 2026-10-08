"""Stand-in for the game side of the bridge, for smoke tests without Project Zomboid.

Mimics Bridge.lua: appends request lines, polls the response file, matches replies by id.

    python tools/fake_game.py --lua-dir <dir> [--pings 3]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from alifebrain_sidecar.protocol import REQ_FILE, RES_FILE  # noqa: E402


class FakeGame:
    def __init__(self, lua_dir: Path) -> None:
        self.lua_dir = lua_dir
        self.session = f"{int(time.time() * 1000)}-fake"
        self.seq = 0
        self.last_rseq = 0
        self.sid: str | None = None

    def now(self) -> int:
        return int(time.time() * 1000)

    def send(self, kind: str, data=None) -> str:
        self.seq += 1
        message = {"v": 1, "id": f"{self.session}:{self.seq}", "sess": self.session, "type": kind,
                   "ts": self.now(), "data": data}
        if self.sid and self.last_rseq:
            message["ack"] = {"sid": self.sid, "rseq": self.last_rseq}
        with (self.lua_dir / REQ_FILE).open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(message) + "\n")
        return message["id"]

    def read(self):
        try:
            lines = (self.lua_dir / RES_FILE).read_text(encoding="utf-8").splitlines()
        except (FileNotFoundError, PermissionError):
            return None, []
        if not lines:
            return None, []
        status = json.loads(lines[0])
        if status.get("sid") != self.sid:
            self.sid, self.last_rseq = status.get("sid"), 0
        fresh = []
        for text in lines[1:]:
            message = json.loads(text)
            if message["rseq"] > self.last_rseq:
                self.last_rseq = message["rseq"]
                fresh.append(message)
        return status, fresh

    def wait_online(self, timeout_s: float = 10) -> dict:
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            status, _ = self.read()
            if status and abs(self.now() - status["ts"]) <= 4000:
                return status
            time.sleep(0.25)
        raise SystemExit("FAIL: sidecar never came online")

    def call(self, kind: str, data=None, timeout_s: float = 5) -> tuple[dict, float]:
        started = time.perf_counter()
        request_id = self.send(kind, data)
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            _, messages = self.read()
            for message in messages:
                if message.get("re") == request_id:
                    return message, (time.perf_counter() - started) * 1000
            time.sleep(0.05)
        raise SystemExit(f"FAIL: no reply to {kind}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lua-dir", type=Path, required=True)
    parser.add_argument("--pings", type=int, default=3)
    args = parser.parse_args()

    game = FakeGame(args.lua_dir)
    status = game.wait_online()
    print(f"online: sid={status['sid']} ver={status['ver']} beat={status['beat']}")

    reply, ms = game.call("hello", {"mod": "ALifeBrain", "modVersion": "fake", "game": "fake"})
    print(f"hello -> ok={reply['ok']} data={reply.get('data')} ({ms:.0f} ms)")
    for index in range(args.pings):
        reply, ms = game.call("ping", {"sentAt": game.now(), "text": "Merhaba, çay içer misin? Şeker yok."})
        print(f"ping {index + 1} -> echo={reply['data']['echo']['text']!r} ({ms:.0f} ms)")

    game.send("event", {"kind": "npc_hit", "npc": {"uid": "palife:smoke:1"}, "by": {"kind": "player", "key": "sp:0"}})
    reply, _ = game.call("teleport")
    print(f"unknown type -> ok={reply['ok']} error={reply.get('error')}")

    # While the "game" holds the request file open, the sidecar must not claim it.
    request_path = args.lua_dir / REQ_FILE
    with request_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({"v": 1, "id": f"{game.session}:held", "sess": game.session,
                                 "type": "ping", "ts": game.now()}) + "\n")
        handle.flush()
        time.sleep(0.5)
        claimed_while_open = not request_path.exists()
    print(f"claimed while held open: {claimed_while_open} (expected False on Windows)")

    deadline = time.time() + 5
    got_held = False
    while time.time() < deadline and not got_held:
        _, messages = game.read()
        got_held = any(m.get("re") == f"{game.session}:held" for m in messages)
        time.sleep(0.05)
    print(f"held request answered after release: {got_held}")

    game.send("ack")
    time.sleep(1.5)
    _, leftover = game.read()
    status, _ = game.read()
    lines = (args.lua_dir / RES_FILE).read_text(encoding="utf-8").splitlines()
    print(f"response lines after ack: {len(lines) - 1}")

    ok = (not claimed_while_open or os.name != "nt") and got_held and len(lines) == 1
    print("SMOKE OK" if ok else "SMOKE FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
