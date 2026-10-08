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

-- Returns { passed, failed, failures = { "suite > case: error" } }.
function Tests.runAll(printer)
    printer = printer or print
    local result = { passed = 0, failed = 0, failures = {} }
    for _, suite in ipairs(Tests.suites) do
        for _, case in ipairs(suite.cases) do
            local ok, err = pcall(case[2], check)
            if ok then
                result.passed = result.passed + 1
            else
                result.failed = result.failed + 1
                local line = suite.name .. " > " .. case[1] .. ": " .. tostring(err)
                result.failures[#result.failures + 1] = line
                printer("[test] FAIL " .. line)
            end
        end
    end
    printer("[test] " .. tostring(result.passed) .. " passed, " .. tostring(result.failed) .. " failed"
        .. (ALifeBrain.Json and ALifeBrain.Json.WIDE_CHARS and " (Kahlua wide chars)" or " (byte strings)"))
    return result
end

return Tests
