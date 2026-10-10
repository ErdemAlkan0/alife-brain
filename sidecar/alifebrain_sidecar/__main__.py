"""Command line entry point: python -m alifebrain_sidecar"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import time
from logging.handlers import RotatingFileHandler
from pathlib import Path

from . import __version__
from .app import Sidecar
from .config import PROVIDERS, load_settings
from .dataset import DatasetStore
from .events import EventStore
from .files import FileBridge
from .llm import LLMError, build_provider
from .memory import MemoryStore

log = logging.getLogger("alifebrain_sidecar")


def default_lua_dir() -> Path:
    return Path.home() / "Zomboid" / "Lua"


def default_data_dir() -> Path:
    local = os.environ.get("LOCALAPPDATA")
    if local:
        return Path(local) / "ALifeBrain"
    return Path.home() / ".local" / "share" / "alifebrain"


class SingleInstance:
    """Exclusive lock in the data folder so two sidecars never fight over the bridge files."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.handle = None

    def __enter__(self) -> "SingleInstance":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.handle = open(self.path, "a+")
        try:
            if os.name == "nt":
                import msvcrt

                self.handle.seek(0)
                msvcrt.locking(self.handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.handle.close()
            raise SystemExit(f"another sidecar is already running (lock: {self.path})")
        return self

    def __exit__(self, *exc: object) -> None:
        if self.handle is not None:
            self.handle.close()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="alifebrain-sidecar", description="A-Life Brain sidecar")
    parser.add_argument("--lua-dir", type=Path, default=default_lua_dir(),
                        help="Project Zomboid Lua folder (default: %(default)s)")
    parser.add_argument("--data-dir", type=Path, default=default_data_dir(),
                        help="where events and memory are stored (default: %(default)s)")
    parser.add_argument("--provider", choices=PROVIDERS,
                        help="override the provider from config.json (fake = canned replies, no LLM)")
    parser.add_argument("--interval", type=float, default=0.05, help="seconds between steps")
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("--version", action="version", version=__version__)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if not args.lua_dir.is_dir():
        log.error("Lua folder not found: %s (start Project Zomboid once, or pass --lua-dir)", args.lua_dir)
        return 2

    with SingleInstance(args.data_dir / "sidecar.lock"):
        # Same log in a file, so a session can be inspected after the console window is closed.
        file_log = RotatingFileHandler(args.data_dir / "sidecar.log", maxBytes=2_000_000, backupCount=3,
                                       encoding="utf-8")
        file_log.setLevel(logging.DEBUG if args.verbose else logging.INFO)
        file_log.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
        logging.getLogger().addHandler(file_log)
        config_path = args.data_dir / "config.json"
        settings = load_settings(config_path)
        if args.provider:
            settings.provider = args.provider
        provider = None
        try:
            provider = build_provider(settings)
        except LLMError as error:
            log.error("LLM provider %s unavailable (%s); dialogue disabled, A-Life lines are used", settings.provider,
                      error)
        if settings.provider == "player2" and not settings.player2.client_id:
            log.warning("Player2 client id missing: create one at https://player2.game/profile/developer and put it "
                        "in %s (player2.client_id) or ALIFEBRAIN_PLAYER2_CLIENT_ID", config_path)

        memory = MemoryStore(args.data_dir / "memory.sqlite3")
        sidecar = Sidecar(FileBridge(args.lua_dir), EventStore(args.data_dir / "events.jsonl"), memory=memory,
                          dataset=DatasetStore(args.data_dir / "dataset"), provider=provider,
                          dialogue=settings.dialogue,
                          health_interval_ms=settings.player2.health_interval_s * 1000)
        log.info("sidecar %s sid=%s provider=%s watching %s, data in %s", __version__, sidecar.sid,
                 settings.provider, args.lua_dir, args.data_dir)
        try:
            while True:
                sidecar.step()
                time.sleep(args.interval)
        except KeyboardInterrupt:
            log.info("stopped; stats=%s", sidecar.stats)
        finally:
            sidecar.close()
            memory.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
