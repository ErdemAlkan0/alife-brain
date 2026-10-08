"""Command line entry point: python -m alifebrain_sidecar"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import time
from pathlib import Path

from . import __version__
from .app import Sidecar
from .events import EventStore
from .files import FileBridge

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
        sidecar = Sidecar(FileBridge(args.lua_dir), EventStore(args.data_dir / "events.jsonl"))
        log.info("sidecar %s sid=%s watching %s, data in %s", __version__, sidecar.sid, args.lua_dir, args.data_dir)
        try:
            while True:
                sidecar.step()
                time.sleep(args.interval)
        except KeyboardInterrupt:
            log.info("stopped; stats=%s", sidecar.stats)
    return 0


if __name__ == "__main__":
    sys.exit(main())
