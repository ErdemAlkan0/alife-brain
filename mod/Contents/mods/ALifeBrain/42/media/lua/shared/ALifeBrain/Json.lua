-- Pure Lua 5.1 JSON encoder/decoder that also runs under Kahlua (Project Zomboid).
--
-- Kahlua strings are Java strings: string.byte returns UTF-16 code units (can be > 255)
-- and string.char accepts them. Standard Lua strings are byte strings holding UTF-8.
-- The encoder always escapes non-ASCII as \uXXXX, so the wire format is pure ASCII and
-- the file encoding used by getFileWriter/getFileReader does not matter.

ALifeBrain = ALifeBrain or {}

local Json = {}
ALifeBrain.Json = Json

local byte, char, sub, concat = string.byte, string.char, string.sub, table.concat
local floor = math.floor

local WIDE_CHARS = false
do
    local ok, value = pcall(char, 300)
    WIDE_CHARS = ok and value ~= nil and byte(value) == 300
end
Json.WIDE_CHARS = WIDE_CHARS

Json.MAX_DEPTH = 64

local ARRAY_MT = { __jsonArray = true }

-- Marks a table so it encodes as a JSON array even when empty.
function Json.array(t)
    return setmetatable(t or {}, ARRAY_MT)
end

local function smallIntToString(value, width)
    local digits = {}
    repeat
        local digit = value % 10
        digits[#digits + 1] = char(48 + digit)
        value = (value - digit) / 10
    until value == 0
    while #digits < width do digits[#digits + 1] = "0" end
    local out = {}
    for index = #digits, 1, -1 do out[#out + 1] = digits[index] end
    return concat(out)
end

-- Kahlua evaluates a % b through a 32-bit integer cast, so it goes wrong once a / b exceeds
-- 2^31 (millisecond timestamps do). Split into 6-digit chunks so % only sees small values.
function Json.intToString(value)
    local negative = value < 0
    if negative then value = -value end
    local chunks = {}
    repeat
        local high = floor(value / 1000000)
        chunks[#chunks + 1] = value - high * 1000000
        value = high
    until value == 0
    local out = { negative and "-" or "" }
    for index = #chunks, 1, -1 do
        out[#out + 1] = smallIntToString(chunks[index], index == #chunks and 1 or 6)
    end
    return concat(out)
end

local HEX = "0123456789abcdef"
local function hex4(value)
    local out = {}
    for index = 4, 1, -1 do
        local digit = value % 16
        out[index] = sub(HEX, digit + 1, digit + 1)
        value = (value - digit) / 16
    end
    return concat(out)
end

local function escapeCodepoint(codepoint)
    if codepoint < 0x10000 then return "\\u" .. hex4(codepoint) end
    local shifted = codepoint - 0x10000
    local high = 0xD800 + floor(shifted / 1024)
    local low = 0xDC00 + shifted % 1024
    return "\\u" .. hex4(high) .. "\\u" .. hex4(low)
end

-- Byte-string mode only: decodes one UTF-8 sequence starting at index.
local function decodeUtf8(s, index)
    local lead = byte(s, index)
    local length, codepoint
    if lead >= 0xF8 or lead < 0xC0 then return nil, 1 end
    if lead >= 0xF0 then length, codepoint = 4, lead - 0xF0
    elseif lead >= 0xE0 then length, codepoint = 3, lead - 0xE0
    else length, codepoint = 2, lead - 0xC0 end
    for offset = 1, length - 1 do
        local continuation = byte(s, index + offset)
        if continuation == nil or continuation < 0x80 or continuation >= 0xC0 then return nil, 1 end
        codepoint = codepoint * 64 + (continuation - 0x80)
    end
    return codepoint, length
end

local function encodeUtf8(codepoint)
    if codepoint < 0x80 then return char(codepoint) end
    if codepoint < 0x800 then
        return char(0xC0 + floor(codepoint / 64), 0x80 + codepoint % 64)
    end
    if codepoint < 0x10000 then
        return char(0xE0 + floor(codepoint / 4096), 0x80 + floor(codepoint / 64) % 64, 0x80 + codepoint % 64)
    end
    return char(0xF0 + floor(codepoint / 262144), 0x80 + floor(codepoint / 4096) % 64,
        0x80 + floor(codepoint / 64) % 64, 0x80 + codepoint % 64)
end

local SIMPLE_ESCAPES = {
    [8] = "\\b", [9] = "\\t", [10] = "\\n", [12] = "\\f", [13] = "\\r", [34] = "\\\"", [92] = "\\\\",
}

local function encodeString(s)
    local out = { "\"" }
    local runStart, index, length = 1, 1, #s
    while index <= length do
        local code = byte(s, index)
        local escaped, width = nil, 1
        if code < 32 or code == 34 or code == 92 then
            escaped = SIMPLE_ESCAPES[code] or ("\\u" .. hex4(code))
        elseif code >= 127 then
            if WIDE_CHARS or code == 127 then
                escaped = "\\u" .. hex4(code)
            else
                local codepoint, size = decodeUtf8(s, index)
                escaped = codepoint and escapeCodepoint(codepoint) or "\\ufffd"
                width = size
            end
        end
        if escaped ~= nil then
            if runStart < index then out[#out + 1] = sub(s, runStart, index - 1) end
            out[#out + 1] = escaped
            index = index + width
            runStart = index
        else
            index = index + 1
        end
    end
    if runStart <= length then out[#out + 1] = sub(s, runStart, length) end
    out[#out + 1] = "\""
    return concat(out)
end

local function encodeNumber(value)
    if value ~= value or value == math.huge or value == -math.huge then return "null" end
    if value == floor(value) and value > -1e15 and value < 1e15 then return Json.intToString(value) end
    local text = tostring(value)
    if string.find(text, "^-?%d+%.?%d*[eE]?[-+]?%d*$") == nil then return "null" end
    return text
end

local function isArray(t)
    if getmetatable(t) == ARRAY_MT then return true end
    local count = 0
    for key in pairs(t) do
        if type(key) ~= "number" or key < 1 or key ~= floor(key) then return false end
        count = count + 1
    end
    if count == 0 then return false end
    for index = 1, count do
        if t[index] == nil then return false end
    end
    return true
end

local function keyLess(left, right) return left.text < right.text end

local encodeValue

local function encodeTable(t, depth, stack)
    if depth > Json.MAX_DEPTH then error("json_too_deep") end
    if stack[t] then error("json_cycle") end
    stack[t] = true
    local out = {}
    if isArray(t) then
        for index = 1, #t do out[index] = encodeValue(t[index], depth + 1, stack) end
        stack[t] = nil
        return "[" .. concat(out, ",") .. "]"
    end
    local keys = {}
    for key in pairs(t) do
        local kind = type(key)
        if kind == "string" then
            keys[#keys + 1] = { key = key, text = key }
        elseif kind == "number" then
            keys[#keys + 1] = { key = key, text = encodeNumber(key) }
        else
            error("json_key_type:" .. kind)
        end
    end
    table.sort(keys, keyLess)
    for index, entry in ipairs(keys) do
        out[index] = encodeString(entry.text) .. ":" .. encodeValue(t[entry.key], depth + 1, stack)
    end
    stack[t] = nil
    return "{" .. concat(out, ",") .. "}"
end

encodeValue = function(value, depth, stack)
    local kind = type(value)
    if value == nil or value == Json.null then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then return encodeNumber(value) end
    if kind == "string" then return encodeString(value) end
    if kind == "table" then return encodeTable(value, depth, stack) end
    error("json_value_type:" .. kind)
end

-- Sentinel for an explicit JSON null inside arrays.
Json.null = setmetatable({}, { __tostring = function() return "null" end })

-- Returns the JSON text, or nil and an error message.
function Json.encode(value)
    local ok, result = pcall(encodeValue, value, 0, {})
    if ok then return result end
    return nil, tostring(result)
end

-- Decoder -----------------------------------------------------------------

local WHITESPACE = { [9] = true, [10] = true, [13] = true, [32] = true }
local NUMBER_CHARS = {}
for code = 48, 57 do NUMBER_CHARS[code] = true end
NUMBER_CHARS[43], NUMBER_CHARS[45], NUMBER_CHARS[46], NUMBER_CHARS[69], NUMBER_CHARS[101] = true, true, true, true, true

local DECODE_ESCAPES = { [34] = "\"", [92] = "\\", [47] = "/", [98] = "\b", [102] = "\f", [110] = "\n", [114] = "\r", [116] = "\t" }

local function fail(message, index)
    error({ json = true, message = message .. " at " .. tostring(index) })
end

local function skip(s, index)
    local code = byte(s, index)
    while code ~= nil and WHITESPACE[code] do
        index = index + 1
        code = byte(s, index)
    end
    return index
end

local function parseHex4(s, index)
    local text = sub(s, index, index + 3)
    if #text ~= 4 or string.find(text, "^%x%x%x%x$") == nil then fail("bad_unicode_escape", index) end
    return tonumber(text, 16)
end

local function decodeString(s, index)
    local out = {}
    local position = index + 1
    while true do
        local stop = string.find(s, "[\"\\]", position)
        if stop == nil then fail("unterminated_string", index) end
        if stop > position then out[#out + 1] = sub(s, position, stop - 1) end
        if byte(s, stop) == 34 then return concat(out), stop + 1 end
        local escape = byte(s, stop + 1)
        if escape == 117 then
            local code = parseHex4(s, stop + 2)
            position = stop + 6
            if WIDE_CHARS then
                out[#out + 1] = char(code)
            else
                if code >= 0xD800 and code <= 0xDBFF and sub(s, position, position + 1) == "\\u" then
                    local low = parseHex4(s, position + 2)
                    if low >= 0xDC00 and low <= 0xDFFF then
                        code = 0x10000 + (code - 0xD800) * 1024 + (low - 0xDC00)
                        position = position + 6
                    end
                end
                if code >= 0xD800 and code <= 0xDFFF then code = 0xFFFD end
                out[#out + 1] = encodeUtf8(code)
            end
        else
            local replacement = escape and DECODE_ESCAPES[escape]
            if replacement == nil then fail("bad_escape", stop) end
            out[#out + 1] = replacement
            position = stop + 2
        end
    end
end

local decodeValue

local function decodeArray(s, index, depth)
    local result, count = Json.array({}), 0
    index = skip(s, index + 1)
    if byte(s, index) == 93 then return result, index + 1 end
    while true do
        local value
        value, index = decodeValue(s, index, depth + 1)
        count = count + 1
        result[count] = value
        index = skip(s, index)
        local code = byte(s, index)
        if code == 93 then return result, index + 1 end
        if code ~= 44 then fail("expected_comma_or_bracket", index) end
        index = skip(s, index + 1)
    end
end

local function decodeObject(s, index, depth)
    local result = {}
    index = skip(s, index + 1)
    if byte(s, index) == 125 then return result, index + 1 end
    while true do
        if byte(s, index) ~= 34 then fail("expected_key", index) end
        local key
        key, index = decodeString(s, index)
        index = skip(s, index)
        if byte(s, index) ~= 58 then fail("expected_colon", index) end
        local value
        value, index = decodeValue(s, skip(s, index + 1), depth + 1)
        result[key] = value
        index = skip(s, index)
        local code = byte(s, index)
        if code == 125 then return result, index + 1 end
        if code ~= 44 then fail("expected_comma_or_brace", index) end
        index = skip(s, index + 1)
    end
end

decodeValue = function(s, index, depth)
    if depth > Json.MAX_DEPTH then fail("too_deep", index) end
    index = skip(s, index)
    local code = byte(s, index)
    if code == nil then fail("unexpected_end", index) end
    if code == 123 then return decodeObject(s, index, depth) end
    if code == 91 then return decodeArray(s, index, depth) end
    if code == 34 then return decodeString(s, index) end
    if code == 116 and sub(s, index, index + 3) == "true" then return true, index + 4 end
    if code == 102 and sub(s, index, index + 4) == "false" then return false, index + 5 end
    if code == 110 and sub(s, index, index + 3) == "null" then return nil, index + 4 end
    if NUMBER_CHARS[code] then
        local stop = index
        while NUMBER_CHARS[byte(s, stop) or 0] do stop = stop + 1 end
        local number = tonumber(sub(s, index, stop - 1))
        if number == nil then fail("bad_number", index) end
        return number, stop
    end
    fail("unexpected_character", index)
end

-- Returns the decoded value, or nil and an error message. JSON null decodes to nil.
function Json.decode(text)
    if type(text) ~= "string" then return nil, "json_input_not_string" end
    local ok, value, index = pcall(decodeValue, text, 1, 0)
    if not ok then
        if type(value) == "table" and value.json then return nil, value.message end
        return nil, tostring(value)
    end
    if skip(text, index) <= #text then return nil, "trailing_characters at " .. tostring(index) end
    return value
end

return Json
