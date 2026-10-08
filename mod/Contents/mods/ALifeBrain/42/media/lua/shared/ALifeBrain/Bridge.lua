-- File bridge between the game (Kahlua) and the Python sidecar.
-- Protocol: docs/bridge-protocol.md
--
--   Lua     appends request lines to  Zomboid/Lua/alifebrain_req.txt
--   sidecar claims that file by renaming it, so Lua never truncates it.
--   sidecar atomically replaces       Zomboid/Lua/alifebrain_res.txt
--           (status line + responses not yet acknowledged); Lua re-reads it on a timer.
--
-- The files hold JSON lines but must end in .txt: B42's getFileWriter only writes
-- txt / ini / cfg / json / lua / log files and silently refuses anything else.
--
-- Nothing is written while the sidecar is offline (events wait in a capped in-memory
-- backlog), so a missing sidecar never grows files on disk.

require "ALifeBrain/Json"

ALifeBrain = ALifeBrain or {}

local Json = ALifeBrain.Json

local Bridge = {
    PROTOCOL = 1,
    REQ_FILE = "alifebrain_req.txt",
    RES_FILE = "alifebrain_res.txt",
    defaults = {
        pollIntervalMs = 250,
        aliveTimeoutMs = 4000,
        defaultTimeoutMs = 8000,
        ackIntervalMs = 1000,
        maxOutbox = 256,
        maxEventBacklog = 200,
        maxLineLength = 16000,
    },
}
Bridge.__index = Bridge
ALifeBrain.Bridge = Bridge

local gameAdapters = {}

function gameAdapters.nowMs()
    if type(getTimestampMs) == "function" then return getTimestampMs() end
    return math.floor(os.time() * 1000)
end

function gameAdapters.random(maximum)
    if type(ZombRand) == "function" then return ZombRand(maximum) end
    return math.random(0, maximum - 1)
end

function gameAdapters.readLines(name)
    local reader = getFileReader(name, false)
    if reader == nil then return nil end
    local lines = {}
    local ok, err = pcall(function()
        local line = reader:readLine()
        while line ~= nil do
            lines[#lines + 1] = line
            line = reader:readLine()
        end
    end)
    pcall(function() reader:close() end)
    if not ok then return nil, tostring(err) end
    return lines
end

function gameAdapters.appendLines(name, lines)
    local writer = getFileWriter(name, true, true)
    if writer == nil then return false, "getFileWriter returned nil" end
    local ok, err = pcall(function() writer:write(table.concat(lines, "\n") .. "\n") end)
    pcall(function() writer:close() end)
    if not ok then return false, tostring(err) end
    return true
end

function gameAdapters.log(message)
    print("[ALifeBrain] " .. tostring(message))
end
Bridge.gameAdapters = gameAdapters

-- options.adapters: overrides for nowMs / random / readLines / appendLines / log.
-- options.settings: overrides for Bridge.defaults.
function Bridge.new(options)
    options = type(options) == "table" and options or {}
    local self = setmetatable({}, Bridge)
    self.adapters = {}
    for name, fn in pairs(gameAdapters) do self.adapters[name] = fn end
    for name, fn in pairs(options.adapters or {}) do self.adapters[name] = fn end
    self.settings = {}
    for key, value in pairs(Bridge.defaults) do self.settings[key] = value end
    for key, value in pairs(options.settings or {}) do self.settings[key] = value end
    self.handlers = {}
    self.statusListeners = {}
    self.started = false
    self:reset()
    return self
end

function Bridge:reset()
    self.sessionId = nil
    self.seq = 0
    self.outbox = {}
    self.eventBacklog = {}
    self.pending = {}
    self.online = false
    self.sidecar = { sid = nil, version = nil, beat = nil, beatChangedAtMs = nil, ts = nil }
    self.lastRseq = 0
    self.ackSentRseq = 0
    self.lastAckAtMs = -math.huge
    self.lastPollAtMs = -math.huge
    self.metrics = { sent = 0, received = 0, timeouts = 0, dropped = 0, badLines = 0, writeFailures = 0 }
end

function Bridge:now() return self.adapters.nowMs() end

function Bridge:log(message) pcall(self.adapters.log, message) end

-- meta: free-form table the caller can send with its hello request.
function Bridge:start(meta)
    self:reset()
    self.meta = type(meta) == "table" and meta or {}
    self.sessionId = Json.intToString(math.floor(self:now())) .. "-"
        .. Json.intToString(self.adapters.random(1000000))
    self.started = true
    return self.sessionId
end

function Bridge:stop()
    self:failPending("stopped")
    self.started = false
    self.online = false
end

function Bridge:isOnline() return self.started and self.online end

-- fn(online, sidecarInfo) is called whenever the online state flips.
function Bridge:onStatusChange(fn)
    self.statusListeners[#self.statusListeners + 1] = fn
end

-- fn(data, message) handles unsolicited "push" messages of the given kind.
function Bridge:on(kind, fn)
    self.handlers[kind] = fn
end

function Bridge:envelope(kind, data)
    self.seq = self.seq + 1
    local message = {
        v = Bridge.PROTOCOL,
        id = self.sessionId .. ":" .. Json.intToString(self.seq),
        sess = self.sessionId,
        type = kind,
        ts = math.floor(self:now()),
        data = data,
    }
    if self.sidecar.sid ~= nil and self.lastRseq > 0 then
        message.ack = { sid = self.sidecar.sid, rseq = self.lastRseq }
    end
    return message
end

function Bridge:enqueue(message)
    local line, err = Json.encode(message)
    if line == nil then
        self:log("encode failed for " .. tostring(message.type) .. ": " .. tostring(err))
        return false, "encode_failed"
    end
    if #line > self.settings.maxLineLength then return false, "message_too_large" end
    if #self.outbox >= self.settings.maxOutbox then
        self.metrics.dropped = self.metrics.dropped + 1
        return false, "outbox_full"
    end
    self.outbox[#self.outbox + 1] = line
    if message.ack ~= nil then self.ackSentRseq = message.ack.rseq end
    return true
end

-- Sends a request; callback(ok, dataOrError) runs exactly once: with the sidecar's answer,
-- or with ok=false and "offline" / "timeout" / "stopped" / the sidecar's error string.
-- Returns the request id, or nil and a reason (then the callback is never called).
function Bridge:request(kind, data, callback, timeoutMs)
    if not self.started then return nil, "not_started" end
    if not self.online then return nil, "offline" end
    local message = self:envelope(kind, data)
    local ok, reason = self:enqueue(message)
    if not ok then return nil, reason end
    local now = self:now()
    self.pending[message.id] = {
        kind = kind,
        callback = callback,
        sentAtMs = now,
        deadlineMs = now + (tonumber(timeoutMs) or self.settings.defaultTimeoutMs),
    }
    return message.id
end

-- Fire-and-forget. While offline, "event" messages wait in a capped backlog that is
-- flushed when the sidecar comes back; anything else is refused.
function Bridge:send(kind, data)
    if not self.started then return false, "not_started" end
    if not self.online then
        if kind ~= "event" then return false, "offline" end
        local backlog = self.eventBacklog
        backlog[#backlog + 1] = { data = data, ts = math.floor(self:now()) }
        while #backlog > self.settings.maxEventBacklog do
            table.remove(backlog, 1)
            self.metrics.dropped = self.metrics.dropped + 1
        end
        return true, "queued"
    end
    return self:enqueue(self:envelope(kind, data))
end

function Bridge:settle(id, ok, value)
    local entry = id ~= nil and self.pending[id] or nil
    if entry == nil then return false end
    self.pending[id] = nil
    if type(entry.callback) == "function" then
        local called, err = pcall(entry.callback, ok, value, entry)
        if not called then self:log("callback for " .. tostring(entry.kind) .. " failed: " .. tostring(err)) end
    end
    return true
end

function Bridge:failPending(reason)
    local ids = {}
    for id in pairs(self.pending) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do self:settle(id, false, reason) end
end

function Bridge:setOnline(online)
    if self.online == online then return end
    self.online = online
    if not online then self:failPending("offline") end
    for _, listener in ipairs(self.statusListeners) do
        local ok, err = pcall(listener, online, self.sidecar)
        if not ok then self:log("status listener failed: " .. tostring(err)) end
    end
    if online then
        local backlog = self.eventBacklog
        self.eventBacklog = {}
        for _, entry in ipairs(backlog) do
            local message = self:envelope("event", entry.data)
            message.ts = entry.ts
            self:enqueue(message)
        end
    end
end

function Bridge:applyStatus(status, now)
    local sidecar = self.sidecar
    if status.sid ~= sidecar.sid then
        sidecar.sid = status.sid
        sidecar.beat = nil
        sidecar.beatChangedAtMs = nil
        self.lastRseq = 0
        self.ackSentRseq = 0
    end
    if status.beat ~= sidecar.beat then
        if sidecar.beat ~= nil then sidecar.beatChangedAtMs = now end
        sidecar.beat = status.beat
    end
    sidecar.version = status.ver
    sidecar.ts = tonumber(status.ts)
    local timeout = self.settings.aliveTimeoutMs
    local fresh = sidecar.ts ~= nil and math.abs(now - sidecar.ts) <= timeout
    local beating = sidecar.beatChangedAtMs ~= nil and now - sidecar.beatChangedAtMs <= timeout
    return fresh or beating
end

function Bridge:handleMessage(message)
    local rseq = tonumber(message.rseq)
    if rseq == nil or rseq <= self.lastRseq then return end
    self.lastRseq = rseq
    self.metrics.received = self.metrics.received + 1
    if message.type == "res" then
        if message.ok == true then
            self:settle(message.re, true, message.data)
        else
            self:settle(message.re, false, message.error or "sidecar_error")
        end
    elseif message.type == "push" then
        if message.sess ~= nil and message.sess ~= self.sessionId then return end
        local handler = self.handlers[message.kind]
        if type(handler) == "function" then
            local ok, err = pcall(handler, message.data, message)
            if not ok then self:log("push handler " .. tostring(message.kind) .. " failed: " .. tostring(err)) end
        end
    end
end

-- Reads the response file. Returns true when the sidecar looks alive.
function Bridge:poll(now)
    local lines = self.adapters.readLines(Bridge.RES_FILE)
    if lines == nil or #lines == 0 then return false end
    local status = Json.decode(lines[1])
    if type(status) ~= "table" or status.type ~= "status" or status.v ~= Bridge.PROTOCOL then
        self.metrics.badLines = self.metrics.badLines + 1
        return false
    end
    local alive = self:applyStatus(status, now)
    for index = 2, #lines do
        local message = Json.decode(lines[index])
        if type(message) == "table" then
            self:handleMessage(message)
        elseif lines[index] ~= "" then
            self.metrics.badLines = self.metrics.badLines + 1
        end
    end
    return alive
end

function Bridge:expire(now)
    local expired = {}
    for id, entry in pairs(self.pending) do
        if now >= entry.deadlineMs then expired[#expired + 1] = id end
    end
    for _, id in ipairs(expired) do
        self.metrics.timeouts = self.metrics.timeouts + 1
        self:settle(id, false, "timeout")
    end
end

function Bridge:flush()
    if #self.outbox == 0 then return end
    local ok, err = self.adapters.appendLines(Bridge.REQ_FILE, self.outbox)
    if ok then
        self.metrics.sent = self.metrics.sent + #self.outbox
        self.outbox = {}
    else
        self.metrics.writeFailures = self.metrics.writeFailures + 1
        if self.metrics.writeFailures == 1 or self.metrics.writeFailures % 100 == 0 then
            self:log("cannot write " .. Bridge.REQ_FILE .. " (failure #" .. Json.intToString(self.metrics.writeFailures)
                .. "): " .. tostring(err or "unknown"))
        end
    end
end

-- Call every game tick; work is throttled to settings.pollIntervalMs.
function Bridge:tick()
    if not self.started then return end
    local now = self:now()
    if now - self.lastPollAtMs < self.settings.pollIntervalMs then return end
    self.lastPollAtMs = now

    local ok, alive = pcall(self.poll, self, now)
    if not ok then
        self:log("poll failed: " .. tostring(alive))
        alive = false
    end
    self:setOnline(alive == true)
    self:expire(now)

    if self.online and #self.outbox == 0 and self.lastRseq > self.ackSentRseq
            and now - self.lastAckAtMs >= self.settings.ackIntervalMs then
        self.lastAckAtMs = now
        self:enqueue(self:envelope("ack", nil))
    end
    if self.online then self:flush() end
end

function Bridge:status()
    local pendingCount = 0
    for _ in pairs(self.pending) do pendingCount = pendingCount + 1 end
    return {
        started = self.started,
        online = self.online,
        session = self.sessionId,
        sidecar = self.sidecar,
        pending = pendingCount,
        outbox = #self.outbox,
        backlog = #self.eventBacklog,
        lastRseq = self.lastRseq,
        metrics = self.metrics,
    }
end

return Bridge
