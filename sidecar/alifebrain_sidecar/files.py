"""File side of the bridge. Only ever touches the four alifebrain_* files in the Lua folder."""

from __future__ import annotations

import logging
import os
from pathlib import Path

from .protocol import CLAIMED_FILE, REQ_FILE, RES_FILE, RES_TMP_FILE

log = logging.getLogger(__name__)


class FileBridge:
    def __init__(self, lua_dir: Path) -> None:
        self.lua_dir = Path(lua_dir)
        self.req_path = self.lua_dir / REQ_FILE
        self.claimed_path = self.lua_dir / CLAIMED_FILE
        self.res_path = self.lua_dir / RES_FILE
        self.res_tmp_path = self.lua_dir / RES_TMP_FILE

    def claim(self) -> list[str]:
        """Takes ownership of everything Lua has written so far and returns its lines.

        Renaming fails while the game holds the file open, so a half-written batch is never
        read; we simply try again on the next step. A claimed file left behind by a crash
        is processed first.
        """
        if not self.claimed_path.exists():
            try:
                os.replace(self.req_path, self.claimed_path)
            except FileNotFoundError:
                return []
            except PermissionError:
                return []
        try:
            text = self.claimed_path.read_text(encoding="utf-8", errors="replace")
        except (FileNotFoundError, PermissionError):
            return []
        try:
            self.claimed_path.unlink()
        except FileNotFoundError:
            pass
        except PermissionError:
            log.warning("could not delete %s; its requests may be seen twice", self.claimed_path)
        return text.splitlines()

    def publish(self, lines: list[str]) -> bool:
        """Atomically replaces the response file. False while the game is reading it."""
        self.res_tmp_path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
        try:
            os.replace(self.res_tmp_path, self.res_path)
        except PermissionError:
            return False
        return True
