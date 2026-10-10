"""Runs the mod's Lua test suites under standard Lua 5.1 through lupa, without the game:

    rl\\.venv\\Scripts\\python -m pip install lupa       (once)
    rl\\.venv\\Scripts\\python tests\\lua\\run_tests.py   (from the repository root)

Kahlua (the game's Lua) is not identical (strings are UTF-16, no next(), ...): the in-game
run (start with -debug, or ALifeBrain.runTests()) stays the final word.
"""

import sys
from pathlib import Path

from lupa import lua51

ROOT = Path(__file__).resolve().parents[2]
SHARED = ROOT / "mod" / "Contents" / "mods" / "ALifeBrain" / "42" / "media" / "lua" / "shared"


def main() -> int:
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f"package.path = [[{SHARED.as_posix()}/?.lua;]] .. package.path")
    lines: list[str] = []
    printer = lua.eval("function(sink) return function(line) sink(tostring(line)) end end")(lines.append)
    result = lua.eval("function(printer) require 'ALifeBrain/Tests/AllTests'; "
                      "return ALifeBrain.Tests.runAll(printer) end")(printer)
    verbose = "-v" in sys.argv[1:]
    for line in lines:
        if verbose or "FAIL" in line or line.startswith("[test]"):
            print(line)
    return 0 if result.failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
