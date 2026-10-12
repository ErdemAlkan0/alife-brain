"""Entry point of the single-file sidecar (sidecar\\build-exe.cmd builds it with PyInstaller):
the same as python -m alifebrain_sidecar, arguments included. Started by a double click, the
console window stays open after an error so the player can read it."""

import sys

from alifebrain_sidecar.__main__ import main


def run() -> int:
    try:
        code = main()
    except SystemExit as stop:
        code = stop.code
    except KeyboardInterrupt:
        code = 0
    if code not in (0, None) and getattr(sys, "frozen", False):
        if isinstance(code, str):
            print(code)
        try:
            input("\nPress Enter to close...")
        except EOFError:
            pass
    return code if isinstance(code, int) else (0 if code is None else 1)


if __name__ == "__main__":
    sys.exit(run())
