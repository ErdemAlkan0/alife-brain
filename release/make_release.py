"""Builds dist\\ALifeBrain-<version>.zip for players: the mod, the sidecar exe and INSTALL.txt.

    python release\\make_release.py

Build the exe first (sidecar\\build-exe.cmd): an exe older than the sidecar's sources is refused.
Only files git tracks go into the mod folder, and this machine's Player2 client id (from
%LOCALAPPDATA%\\ALifeBrain\\config.json, if there is one) must not appear in any file.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOD = Path("mod/Contents/mods/ALifeBrain")
EXE = ROOT / "sidecar" / "dist" / "ALifeBrainSidecar.exe"
EXE_SOURCES = [ROOT / "sidecar" / "alifebrain_sidecar", ROOT / "sidecar" / "packaging"]
NOTE = Path(__file__).resolve().parent / "INSTALL.txt"
OUT = ROOT / "dist"


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, check=True).stdout.decode("utf-8")


def mod_version() -> str:
    for line in (ROOT / MOD / "42" / "mod.info").read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition("=")
        if key.strip() == "modversion":
            return value.strip()
    raise SystemExit("mod.info has no modversion")


def check_exe() -> None:
    if not EXE.exists():
        raise SystemExit(f"{EXE} is missing: run sidecar\\build-exe.cmd first")
    newest = max(path.stat().st_mtime for folder in EXE_SOURCES for path in folder.rglob("*.py"))
    if EXE.stat().st_mtime < newest:
        raise SystemExit("the exe is older than the sidecar's sources: run sidecar\\build-exe.cmd again")


def local_client_id() -> str | None:
    config = Path(os.environ.get("LOCALAPPDATA", "")) / "ALifeBrain" / "config.json"
    try:
        return json.loads(config.read_text(encoding="utf-8")).get("player2", {}).get("client_id") or None
    except (OSError, ValueError, AttributeError):
        return None


def main() -> int:
    version = mod_version()
    check_exe()
    changed = [line for line in git("status", "--porcelain", "--", MOD.as_posix(), "sidecar").splitlines() if line]
    if changed:
        print("warning: uncommitted changes go in as they are on disk:\n  " + "\n  ".join(changed))

    top = f"ALifeBrain-{version}"
    files = [Path(name) for name in git("ls-files", "-z", "--", MOD.as_posix()).split("\0") if name]
    entries = [(ROOT / path, f"{top}/ALifeBrain/{path.relative_to(MOD).as_posix()}") for path in files]
    entries.append((EXE, f"{top}/{EXE.name}"))
    note = NOTE.read_text(encoding="utf-8").replace("{version}", version)
    note = note.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8")  # Notepad-friendly

    secret = local_client_id()
    if secret:
        for source, _ in entries:
            if secret.encode("utf-8") in source.read_bytes():
                raise SystemExit(f"{source} contains this machine's Player2 client id; nothing was written")

    OUT.mkdir(exist_ok=True)
    target = OUT / f"{top}.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for source, name in entries:
            archive.write(source, name)
        archive.writestr(f"{top}/INSTALL.txt", note)
    print(f"{target} ({target.stat().st_size // 1024} KB): {len(files)} mod files, {EXE.name}, INSTALL.txt"
          + ("; checked for this machine's client id" if secret else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
