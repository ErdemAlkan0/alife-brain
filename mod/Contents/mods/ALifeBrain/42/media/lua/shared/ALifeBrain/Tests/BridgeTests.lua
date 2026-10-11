require "ALifeBrain/Json"
require "ALifeBrain/Bridge"
require "ALifeBrain/Tests/TestRunner"

local Json, Bridge = ALifeBrain.Json, ALifeBrain.Bridge

-- In-memory stand-in for Zomboid/Lua plus a fake clock and a fake sidecar.
local function harness(settings)
    local env = { now = 1000000, files = {}, logs = {}, rseq = 0, sid = "sidA", beat = 1 }
    env.bridge = Bridge.new({
        settings = settings,
        adapters = {
            nowMs = function() return env.now end,
            random = function() return 42 end,
            readLines = function(name)
                local file = env.files[name]
                if file == nil then return nil end
                local copy = {}
                for index, line in ipairs(file) do copy[index] = line end
                return copy
            end,
            appendLines = function(name, lines)
                if env.writeFails then return false, "refused" end
                env.files[name] = env.files[name] or {}
                for _, line in ipairs(lines) do table.insert(env.files[name], line) end
                return true
            end,
            log = function(message) env.logs[#env.logs + 1] = message end,
        },
    })

    -- Writes the response file the way the sidecar does: status line first.
    function env.publish(responses, statusOverrides)
        local status = { v = 1, type = "status", sid = env.sid, beat = env.beat, ts = env.now, ver = "test" }
        for key, value in pairs(statusOverrides or {}) do status[key] = value end
        local lines = { Json.encode(status) }
        for _, response in ipairs(responses or {}) do lines[#lines + 1] = Json.encode(response) end
        env.files[Bridge.RES_FILE] = lines
    end

    function env.reply(requestId, data, ok)
        env.rseq = env.rseq + 1
        return { v = 1, type = "res", rseq = env.rseq, re = requestId, ok = ok ~= false, data = data,
            error = ok == false and data or nil }
    end

    -- Claims the request file like the sidecar (rename + read + delete).
    function env.take()
        local lines = env.files[Bridge.REQ_FILE] or {}
        env.files[Bridge.REQ_FILE] = nil
        local messages = {}
        for index, line in ipairs(lines) do messages[index] = Json.decode(line) end
        return messages
    end

    function env.advance(ms)
        env.now = env.now + (ms or 300)
        env.bridge:tick()
    end

    env.bridge:start({ mod = "test" })
    return env
end

local function online(env)
    env.publish()
    env.advance()
    return env.bridge:isOnline()
end

ALifeBrain.Tests.suite("Bridge", {
    { "stays offline and silent without a sidecar", function(check)
        local env = harness()
        env.advance()
        check.equal(env.bridge:isOnline(), false)
        local id, reason = env.bridge:request("ping", {}, function() end)
        check.isNil(id)
        check.equal(reason, "offline")
        check.equal(env.bridge:send("ping", {}), false)
        check.equal(env.bridge:send("event", { kind = "x" }), true, "events are backlogged")
        env.advance()
        check.isNil(env.files[Bridge.REQ_FILE], "nothing written while offline")
    end },

    { "goes online on a fresh status line and notifies listeners", function(check)
        local env = harness()
        local flips = {}
        env.bridge:onStatusChange(function(isOnline) flips[#flips + 1] = isOnline end)
        check.truthy(online(env))
        check.same(flips, { true })
        env.advance()
        check.same(flips, { true }, "no repeated notifications")
    end },

    { "routes a response to its request", function(check)
        local env = harness()
        online(env)
        local got = nil
        local id = env.bridge:request("ping", { n = 1 }, function(ok, data) got = { ok = ok, data = data } end)
        check.truthy(id)
        env.advance()
        local sent = env.take()
        check.equal(#sent, 1)
        check.equal(sent[1].type, "ping")
        check.equal(sent[1].id, id)
        check.equal(sent[1].sess, env.bridge.sessionId)
        check.equal(sent[1].v, 1)
        check.equal(sent[1].data.n, 1)
        env.publish({ env.reply(id, { pong = true }) })
        env.advance()
        check.same(got, { ok = true, data = { pong = true } })
    end },

    { "names the save on every line", function(check)
        local env = harness()
        check.isNil(env.bridge:envelope("ping", {}).world, "no save known")
        env.bridge:start({ mod = "test", world = "Apocalypse/11-10-2026_00-55" })
        online(env)
        env.bridge:request("ping", {}, function() end)
        env.bridge:send("event", { kind = "npc_died" })
        env.advance()
        local sent = env.take()
        check.equal(#sent, 2)
        check.equal(sent[1].world, "Apocalypse/11-10-2026_00-55")
        check.equal(sent[2].world, "Apocalypse/11-10-2026_00-55")
    end },

    { "passes sidecar errors through", function(check)
        local env = harness()
        online(env)
        local got = nil
        local id = env.bridge:request("hello", {}, function(ok, data) got = { ok = ok, data = data } end)
        env.advance()
        env.publish({ env.reply(id, "unknown_type", false) })
        env.advance()
        check.same(got, { ok = false, data = "unknown_type" })
    end },

    { "times out unanswered requests", function(check)
        local env = harness()
        online(env)
        local got = nil
        env.bridge:request("ping", {}, function(ok, data) got = { ok = ok, data = data } end, 500)
        env.advance(300)
        check.isNil(got)
        env.advance(300)
        check.same(got, { ok = false, data = "timeout" })
        check.equal(env.bridge.metrics.timeouts, 1)
    end },

    { "fails pending requests when the sidecar stops beating", function(check)
        local env = harness()
        online(env)
        local got = nil
        env.bridge:request("ping", {}, function(ok, data) got = { ok = ok, data = data } end, 60000)
        local stale = env.now
        env.advance(5000)
        env.publish(nil, { ts = stale })
        env.advance(300)
        check.equal(env.bridge:isOnline(), false)
        check.same(got, { ok = false, data = "offline" })
    end },

    { "rides out a response file it cannot read for a moment", function(check)
        local env = harness()
        online(env)
        local got = nil
        env.bridge:request("ping", {}, function(ok, data) got = { ok = ok, data = data } end, 60000)
        local good = env.files[Bridge.RES_FILE]
        env.files[Bridge.RES_FILE] = nil -- locked while the sidecar swaps it in
        env.advance(300)
        env.files[Bridge.RES_FILE] = { "{\"v\":1,\"type\":\"sta" } -- or caught half-read
        env.advance(300)
        check.equal(env.bridge:isOnline(), true, "still online")
        check.isNil(got, "the pending request lives on")
        env.files[Bridge.RES_FILE] = good
        env.publish(nil)
        env.advance(300)
        check.equal(env.bridge:isOnline(), true)
        env.files[Bridge.RES_FILE] = nil
        env.advance(Bridge.defaults.aliveTimeoutMs + 1)
        check.equal(env.bridge:isOnline(), false, "gone for longer than the alive timeout")
        check.same(got, { ok = false, data = "offline" })
    end },

    { "treats a changing beat as alive even with a skewed clock", function(check)
        local env = harness()
        env.publish(nil, { ts = 1 })
        env.advance()
        check.equal(env.bridge:isOnline(), false)
        env.beat = 2
        env.publish(nil, { ts = 1 })
        env.advance()
        check.equal(env.bridge:isOnline(), true)
    end },

    { "ignores duplicate responses", function(check)
        local env = harness()
        online(env)
        local calls = 0
        local id = env.bridge:request("ping", {}, function() calls = calls + 1 end)
        env.advance()
        local response = env.reply(id, {})
        env.publish({ response })
        env.advance()
        env.publish({ response })
        env.advance()
        check.equal(calls, 1)
    end },

    { "resets sequence numbers when the sidecar restarts", function(check)
        local env = harness()
        online(env)
        env.rseq = 9
        env.publish({ env.reply("unknown", {}) })
        env.advance()
        check.equal(env.bridge.lastRseq, 10)
        local got = false
        local id = env.bridge:request("ping", {}, function(ok) got = ok end)
        env.advance()
        env.sid, env.rseq = "sidB", 0
        env.publish({ env.reply(id, {}) })
        env.advance()
        check.equal(got, true)
        check.equal(env.bridge.lastRseq, 1)
    end },

    { "acknowledges responses on later messages and when idle", function(check)
        local env = harness()
        online(env)
        local id = env.bridge:request("ping", {}, function() end)
        env.advance()
        env.take()
        env.publish({ env.reply(id, {}) })
        env.advance()
        local idle = env.take()
        check.equal(#idle, 1, "explicit ack when nothing else is queued")
        check.equal(idle[1].type, "ack")
        check.same(idle[1].ack, { sid = "sidA", rseq = 1 })
        env.bridge:send("event", { kind = "x" })
        env.advance(2000)
        local later = env.take()
        check.equal(#later, 1)
        check.same(later[1].ack, { sid = "sidA", rseq = 1 }, "acks ride along on other messages")
    end },

    { "flushes the event backlog when the sidecar appears", function(check)
        local env = harness({ maxEventBacklog = 2 })
        env.advance()
        local firstTs = env.now
        env.bridge:send("event", { kind = "a" })
        env.advance()
        env.bridge:send("event", { kind = "b" })
        env.bridge:send("event", { kind = "c" })
        check.equal(env.bridge.metrics.dropped, 1, "oldest event dropped past the cap")
        online(env)
        local sent = env.take()
        check.equal(#sent, 2)
        check.equal(sent[1].data.kind, "b")
        check.equal(sent[2].data.kind, "c")
        check.truthy(sent[1].ts > firstTs and sent[1].ts < env.now, "original timestamps are kept")
    end },

    { "rejects a bad status line", function(check)
        local env = harness()
        env.files[Bridge.RES_FILE] = { "not json", "{}" }
        env.advance()
        check.equal(env.bridge:isOnline(), false)
        check.equal(env.bridge.metrics.badLines, 1)
        env.files[Bridge.RES_FILE] = { Json.encode({ v = 99, type = "status", sid = "x", beat = 1, ts = env.now }) }
        env.advance()
        check.equal(env.bridge:isOnline(), false, "unknown protocol version")
    end },

    { "routes push messages for this session only", function(check)
        local env = harness()
        online(env)
        local got = {}
        env.bridge:on("say", function(data) got[#got + 1] = data.text end)
        env.rseq = env.rseq + 1
        local mine = { v = 1, type = "push", rseq = env.rseq, sess = env.bridge.sessionId, kind = "say", data = { text = "mine" } }
        env.rseq = env.rseq + 1
        local other = { v = 1, type = "push", rseq = env.rseq, sess = "other", kind = "say", data = { text = "other" } }
        env.publish({ mine, other })
        env.advance()
        check.same(got, { "mine" })
    end },

    { "keeps and reports requests the game refuses to write", function(check)
        local env = harness()
        online(env)
        env.writeFails = true
        env.bridge:request("ping", {}, function() end)
        env.advance()
        env.advance()
        check.equal(env.bridge.metrics.writeFailures, 2)
        check.equal(#env.bridge.outbox, 1, "request kept for retry")
        check.equal(#env.logs, 1, "first failure logged once")
        check.truthy(string.find(env.logs[1], "refused", 1, true) ~= nil, env.logs[1])
        env.writeFails = false
        env.advance()
        check.equal(#env.take(), 1, "written once the file is writable")
    end },

    { "uses file names the game is allowed to write", function(check)
        for _, name in ipairs({ Bridge.REQ_FILE, Bridge.RES_FILE }) do
            local extension = string.match(name, "%.([%a]+)$")
            check.truthy(({ txt = true, ini = true, cfg = true, json = true, lua = true, log = true })[extension],
                name .. " must use an extension B42's getFileWriter accepts")
        end
    end },

    { "survives a throwing callback", function(check)
        local env = harness()
        online(env)
        local id = env.bridge:request("ping", {}, function() error("boom") end)
        env.advance()
        env.publish({ env.reply(id, {}) })
        env.advance()
        check.equal(env.bridge:status().pending, 0)
        check.truthy(#env.logs >= 1, "failure was logged")
    end },
})
