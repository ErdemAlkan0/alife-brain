-- Entry point: starts the sidecar bridge, keeps a ping going, runs the in-game tests
-- in debug mode. Debug console helpers: ALifeBrain.status(), ALifeBrain.ping(),
-- ALifeBrain.runTests().

require "ALifeBrain/Json"
require "ALifeBrain/Bridge"
require "ALifeBrain/ALifeBrainHooks"
require "ALifeBrain/EventLog"
require "ALifeBrain/Dialogue"
require "ALifeBrain/ChatWindow"
require "ALifeBrain/Tests/AllTests"

ALifeBrain = ALifeBrain or {}
ALifeBrain.VERSION = "0.1.0"

local Json, Bridge, Hooks = ALifeBrain.Json, ALifeBrain.Bridge, ALifeBrain.Hooks

local Main = {
    settings = { pingIntervalMs = 10000, logEveryNthPong = 6, runTestsInDebug = true },
    lastPingAtMs = -math.huge,
    pongs = 0,
    lastRttMs = nil,
}
ALifeBrain.Main = Main

local function log(message) print("[ALifeBrain] " .. tostring(message)) end

local function nowMs() return getTimestampMs() end

local function halo(text, r, g, b)
    pcall(function()
        local player = getSpecificPlayer(0)
        if player ~= nil then player:setHaloNote(text, r, g, b, 300) end
    end)
end

local function gameVersion()
    local version = nil
    pcall(function() version = tostring(getCore():getVersion()) end)
    if version == nil then pcall(function() version = tostring(getCore():getVersionNumber()) end) end
    return version
end

function Main.hello()
    local bridge = ALifeBrain.bridge
    bridge:request("hello", bridge.meta, function(ok, data)
        if ok and type(data) == "table" then
            local features = {}
            for _, name in ipairs(type(data.features) == "table" and data.features or {}) do features[name] = true end
            bridge.features = features
            log("sidecar ready: version=" .. tostring(data.version) .. " provider=" .. tostring(data.provider)
                .. " features=" .. tostring(Json.encode(data.features)))
        else
            log("hello failed: " .. tostring(data))
        end
    end)
end

function Main.ping()
    local bridge = ALifeBrain.bridge
    if bridge == nil then return nil, "not_started" end
    local sentAt = nowMs()
    Main.lastPingAtMs = sentAt
    return bridge:request("ping", { sentAt = sentAt }, function(ok, data)
        if not ok then
            log("ping failed: " .. tostring(data))
            return
        end
        Main.lastRttMs = math.floor(nowMs() - sentAt)
        Main.pongs = Main.pongs + 1
        if Main.pongs == 1 or Main.pongs % Main.settings.logEveryNthPong == 0 then
            log("pong #" .. Json.intToString(Main.pongs) .. " rtt=" .. Json.intToString(Main.lastRttMs) .. "ms")
        end
    end, 5000)
end

function Main.onStatusChange(online, sidecar)
    if online then
        log("sidecar online sid=" .. tostring(sidecar.sid) .. " version=" .. tostring(sidecar.version))
        halo("A-Life Brain: sidecar connected", 120, 255, 120)
        Main.hello()
        Main.ping()
    else
        ALifeBrain.bridge.features = nil
        log("sidecar offline; A-Life keeps running on its own")
        halo("A-Life Brain: sidecar offline", 255, 170, 90)
    end
end

function Main.onTick()
    local bridge = ALifeBrain.bridge
    if bridge == nil then return end
    bridge:tick()
    ALifeBrain.Dialogue.tick(nowMs())
    if bridge:isOnline() and nowMs() - Main.lastPingAtMs >= Main.settings.pingIntervalMs then
        Main.ping()
    end
end

function Main.reportHooks()
    local report = Hooks.selfCheck()
    local version = Hooks.aLifeVersion()
    log("A-Life " .. tostring(version) .. " (tested with " .. Hooks.TESTED_ALIFE_VERSION .. "): touchpoints ok="
        .. Json.intToString(report.ok) .. " missing=" .. Json.intToString(#report.missing)
        .. " skipped=" .. Json.intToString(report.skipped))
    for _, path in ipairs(report.missing) do log("  missing A-Life touchpoint: ProjectALife." .. path) end
end

function Main.onGameStart()
    if Main.settings.runTestsInDebug and type(getDebug) == "function" and getDebug() then
        ALifeBrain.runTests()
    end
    Main.reportHooks()
    local bridge = Bridge.new()
    bridge:onStatusChange(Main.onStatusChange)
    bridge:start({
        mod = "ALifeBrain",
        modVersion = ALifeBrain.VERSION,
        game = gameVersion(),
        alife = Hooks.aLifeVersion(),
        protocol = Bridge.PROTOCOL,
    })
    ALifeBrain.bridge = bridge
    log("bridge started session=" .. tostring(bridge.sessionId) .. "; waiting for sidecar")

    -- A-Life answers talk on the server; in single player that is this Lua state. Multiplayer
    -- clients need a client-side path (CLAUDE.md), so the hook is single player only for now.
    if type(isClient) == "function" and isClient() then
        log("multiplayer client: LLM dialogue not available yet; A-Life lines are used")
    else
        local installed, reason = Hooks.installTalkHook(ALifeBrain.Dialogue.handle)
        log("LLM dialogue hook " .. (installed and "ready" or "not installed") .. " (" .. tostring(reason) .. ")")
        local keyed, keyReason = Hooks.wrapTalkInput(ALifeBrain.Chat.openFromKey)
        log("chat key opens the conversation window: " .. tostring(keyed) .. " (" .. tostring(keyReason) .. ")")
    end
end

function ALifeBrain.status()
    local bridge = ALifeBrain.bridge
    if bridge == nil then
        log("not started")
        return nil
    end
    local status = bridge:status()
    status.lastRttMs = Main.lastRttMs
    status.events = ALifeBrain.EventLog and ALifeBrain.EventLog.metrics or nil
    status.features = bridge.features
    status.dialogue = ALifeBrain.Dialogue.metrics
    status.dialogueLastError = ALifeBrain.Dialogue.lastError
    log(tostring(Json.encode(status)))
    return status
end

function ALifeBrain.ping() return Main.ping() end

-- Debug console: ALifeBrain.spawnTestNpc() spawns one friendly NPC (Church Volunteers) to talk to;
-- ALifeBrain.spawnTestNpc("alife_hobbs", 3) spawns three Hobbs Brothers (hostile).
function ALifeBrain.spawnTestNpc(factionId, count, encounterId)
    local faction = factionId or "alife_church_volunteers"
    local ok, reason = Hooks.spawnTestNpc(getPlayer(), encounterId or "patrol", count or 1, 6, faction)
    log(ok and ("spawn requested (" .. faction .. "); A-Life answers in its own log")
        or ("spawn failed: " .. tostring(reason)))
    return ok
end

function ALifeBrain.runTests()
    return ALifeBrain.Tests.runAll(log)
end

if type(Events) == "table" then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(Main.onGameStart) end
    if Events.OnTick ~= nil then Events.OnTick.Add(Main.onTick) end
end

return Main
