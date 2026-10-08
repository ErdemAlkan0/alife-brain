require "ALifeBrain/Json"
require "ALifeBrain/Tests/TestRunner"

local Json = ALifeBrain.Json

ALifeBrain.Tests.suite("Json", {
    { "encodes primitives", function(check)
        check.equal(Json.encode(nil), "null")
        check.equal(Json.encode(true), "true")
        check.equal(Json.encode(false), "false")
        check.equal(Json.encode(0), "0")
        check.equal(Json.encode(-12), "-12")
        check.equal(Json.encode(3.5), "3.5")
        check.equal(Json.encode("abc"), "\"abc\"")
    end },

    { "encodes large integers without exponent", function(check)
        check.equal(Json.encode(1759951234567), "1759951234567")
        check.equal(Json.encode(999999999999999), "999999999999999")
        check.equal(Json.intToString(-905), "-905")
        check.equal(Json.intToString(1000000), "1000000")
        check.equal(Json.intToString(7000001), "7000001")
        check.equal(Json.intToString(0), "0")
        check.equal(Json.intToString(2147483648), "2147483648")
    end },

    { "encodes non-finite numbers as null", function(check)
        check.equal(Json.encode(math.huge), "null")
        check.equal(Json.encode(-math.huge), "null")
        check.equal(Json.encode(0 / 0), "null")
    end },

    { "sorts object keys", function(check)
        check.equal(Json.encode({ b = 1, a = 2, c = { z = true, y = false } }), "{\"a\":2,\"b\":1,\"c\":{\"y\":false,\"z\":true}}")
    end },

    { "detects arrays", function(check)
        check.equal(Json.encode({ 1, 2, 3 }), "[1,2,3]")
        check.equal(Json.encode({}), "{}")
        check.equal(Json.encode(Json.array({})), "[]")
        check.equal(Json.encode({ [1] = "a", [3] = "c" }), "{\"1\":\"a\",\"3\":\"c\"}")
    end },

    { "escapes control and special characters", function(check)
        check.equal(Json.encode("a\"b\\c\n\t\r"), "\"a\\\"b\\\\c\\n\\t\\r\"")
        check.equal(Json.encode("x\1y"), "\"x\\u0001y\"")
    end },

    { "keeps the wire format ASCII for non-ASCII text", function(check)
        local text = Json.decode("\"\\u015f\\u00e7\\u011f\"")
        check.equal(Json.encode(text), "\"\\u015f\\u00e7\\u011f\"")
        if Json.WIDE_CHARS then
            check.equal(#text, 3, "Kahlua strings hold UTF-16 units")
        else
            check.equal(#text, 6, "byte strings hold UTF-8")
            check.equal(Json.encode("\197\159"), "\"\\u015f\"", "raw UTF-8 input")
        end
    end },

    { "round-trips surrogate pairs", function(check)
        local text = Json.decode("\"\\ud83d\\ude00\"")
        check.equal(Json.encode(text), "\"\\ud83d\\ude00\"")
    end },

    { "decodes nested structures", function(check)
        local value = Json.decode("{\"a\":[1,2,{\"b\":null,\"c\":\"x\"}],\"d\":true}")
        check.equal(value.d, true)
        check.equal(#value.a, 3)
        check.equal(value.a[2], 2)
        check.isNil(value.a[3].b)
        check.equal(value.a[3].c, "x")
    end },

    { "decodes numbers and whitespace", function(check)
        local value = Json.decode(" {\r\n \"n\" : -1.5e2 ,\t\"m\":0.25 } ")
        check.equal(value.n, -150)
        check.equal(value.m, 0.25)
    end },

    { "decodes escapes", function(check)
        check.equal(Json.decode("\"a\\/b\\\\c\\\"d\\n\""), "a/b\\c\"d\n")
    end },

    { "decoded empty arrays encode back as arrays", function(check)
        check.equal(Json.encode(Json.decode("{\"list\":[]}")), "{\"list\":[]}")
    end },

    { "reports malformed input instead of throwing", function(check)
        for _, text in ipairs({ "{\"a\":}", "[1,2", "\"abc", "{} x", "", "tru", "{\"a\" 1}", "\"\\x\"" }) do
            local value, err = Json.decode(text)
            check.isNil(value, "decode(" .. text .. ")")
            check.truthy(type(err) == "string", "error message for " .. text)
        end
        check.isNil(Json.decode(nil))
    end },

    { "refuses cycles, deep nesting and unsupported types", function(check)
        local cyclic = {}
        cyclic.self = cyclic
        local value, err = Json.encode(cyclic)
        check.isNil(value)
        check.truthy(string.find(err, "json_cycle", 1, true) ~= nil, err)

        local deep = {}
        local cursor = deep
        for _ = 1, Json.MAX_DEPTH + 5 do
            cursor[1] = {}
            cursor = cursor[1]
        end
        check.isNil(Json.encode(deep))
        check.isNil(Json.decode(string.rep("[", Json.MAX_DEPTH + 5) .. string.rep("]", Json.MAX_DEPTH + 5)))

        check.isNil(Json.encode({ f = function() end }))
    end },
})
