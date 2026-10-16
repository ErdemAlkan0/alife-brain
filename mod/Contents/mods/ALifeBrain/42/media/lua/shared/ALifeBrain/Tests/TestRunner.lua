-- Minimal test runner that works in Kahlua (in game) and in standard Lua 5.1
-- (tests/lua/run_tests.lua). In game: start with -debug, or call ALifeBrain.runTests().

ALifeBrain = ALifeBrain or {}

local Tests = { suites = {} }
ALifeBrain.Tests = Tests

local function describe(value)
    if type(value) == "string" then return "\"" .. value .. "\"" end
    return tostring(value)
end

local function deepEqual(left, right, seen)
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    seen = seen or {}
    if seen[left] == right then return true end
    seen[left] = right
    for key, value in pairs(left) do
        if not deepEqual(value, right[key], seen) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local check = {}
Tests.check = check

function check.equal(actual, expected, message)
    if actual ~= expected then
        error((message or "not equal") .. ": expected " .. describe(expected) .. ", got " .. describe(actual), 2)
    end
end

function check.same(actual, expected, message)
    if not deepEqual(actual, expected) then
        local json = ALifeBrain.Json
        local shown = json and (tostring(json.encode(expected)) .. " vs " .. tostring(json.encode(actual))) or ""
        error((message or "tables differ") .. ": " .. shown, 2)
    end
end

function check.truthy(value, message)
    if not value then error((message or "expected a truthy value") .. ", got " .. describe(value), 2) end
end

function check.isNil(value, message)
    if value ~= nil then error((message or "expected nil") .. ", got " .. describe(value), 2) end
end

-- cases: array of { name, fn(check) }
function Tests.suite(name, cases)
    for index, existing in ipairs(Tests.suites) do
        if existing.name == name then
            Tests.suites[index] = { name = name, cases = cases }
            return
        end
    end
    Tests.suites[#Tests.suites + 1] = { name = name, cases = cases }
end

-- Saves the named fields of target, runs body() and puts every one back, nil ones included.
-- The tests run in the live game (at startup with -debug): a loop over pairs(saved) skips the
-- nils, and the fakes it should have removed stayed installed (Rapport never saw a real NPC,
-- policy control stayed off; play test, 2026-10-14).
function Tests.keeping(target, fields, body)
    local saved = {}
    for index, field in ipairs(fields) do saved[index] = target[field] end
    local ok, failure = pcall(body)
    for index, field in ipairs(fields) do target[field] = saved[index] end
    if not ok then error(failure, 0) end
end

-- Fields where tests install fakes. Whatever a test run leaves changed fails the run and is put back.
Tests.LIVE_FIELDS = { "override", "forced" }

local function liveFields()
    local snapshot = {}
    for name, module in pairs(ALifeBrain) do
        if type(module) == "table" and module ~= Tests then
            for _, field in ipairs(Tests.LIVE_FIELDS) do
                snapshot[#snapshot + 1] = { module = module, name = name, field = field, value = rawget(module, field) }
            end
        end
    end
    return snapshot
end

-- Returns { passed, failed, failures = { "suite > case: error" } }.
function Tests.runAll(printer)
    printer = printer or print
    local result = { passed = 0, failed = 0, failures = {} }
    local function fail(line)
        result.failed = result.failed + 1
        result.failures[#result.failures + 1] = line
        printer("[test] FAIL " .. line)
    end
    local live = liveFields()
    for _, suite in ipairs(Tests.suites) do
        for _, case in ipairs(suite.cases) do
            local ok, err = pcall(case[2], check)
            if ok then
                result.passed = result.passed + 1
            else
                fail(suite.name .. " > " .. case[1] .. ": " .. tostring(err))
            end
        end
    end
    for _, entry in ipairs(live) do
        if rawget(entry.module, entry.field) ~= entry.value then
            entry.module[entry.field] = entry.value
            fail("test isolation: ALifeBrain." .. entry.name .. "." .. entry.field .. " was left changed (put back)")
        end
    end
    printer("[test] " .. tostring(result.passed) .. " passed, " .. tostring(result.failed) .. " failed"
        .. (ALifeBrain.Json and ALifeBrain.Json.WIDE_CHARS and " (Kahlua wide chars)" or " (byte strings)"))
    return result
end

return Tests
