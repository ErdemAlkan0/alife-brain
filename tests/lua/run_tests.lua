-- Runs the in-game test suites under standard Lua 5.1 / LuaJIT:
--   lua tests/lua/run_tests.lua        (from the repository root)
-- The same suites run under Kahlua in game (start with -debug or call ALifeBrain.runTests()).

local shared = "mod/Contents/mods/ALifeBrain/42/media/lua/shared/"
package.path = shared .. "?.lua;" .. package.path

require "ALifeBrain/Tests/AllTests"

local result = ALifeBrain.Tests.runAll(print)
os.exit(result.failed == 0 and 0 or 1)
