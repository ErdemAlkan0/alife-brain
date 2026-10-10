-- Entry point: starts the sidecar bridge, keeps a ping going, runs the in-game tests
-- in debug mode. Debug console helpers: ALifeBrain.status(), ALifeBrain.ping(),
-- ALifeBrain.runTests(), ALifeBrain.policy(), ALifeBrain.control(on).

require "ALifeBrain/Json"
require "ALifeBrain/Bridge"
require "ALifeBrain/ALifeBrainHooks"
require "ALifeBrain/EventLog"
require "ALifeBrain/Dialogue"
require "ALifeBrain/DecisionLog"
require "ALifeBrain/Moods"
require "ALifeBrain/Control"
require "ALifeBrain/Companion"
require "ALifeBrain/Standoff"
require "ALifeBrain/Parley"
require "ALifeBrain/ChatWindow"
require "ALifeBrain/Tests/AllTests"

ALifeBrain = ALifeBrain or {}
ALifeBrain.VERSION = "0.1.0"

local Json, Bridge, Hooks = ALifeBrain.Json, ALifeBrain.Bridge, ALifeBrain.Hooks

local Main = {
    settings = { pingIntervalMs = 10000, logEveryNthPong = 6, runTestsInDebug = true, modulesRefreshMs = 30000,
        stealthMs = 500 },
    lastPingAtMs = -math.huge,
    modulesAtMs = nil, -- set once our A-Life modules are in
    stealthAtMs = 0,
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
    ALifeBrain.DecisionLog.tick(nowMs())
    ALifeBrain.Moods.tick(nowMs())
    if Main.modulesAtMs ~= nil then
        local now = nowMs()
        ALifeBrain.Parley.tick(now)
        if now - Main.stealthAtMs >= Main.settings.stealthMs then
            Main.stealthAtMs = now
            Hooks.updateFollowerStealth()
        end
        -- Behavior profiles added later (custom factions) get our modules too.
        if now - Main.modulesAtMs >= Main.settings.modulesRefreshMs then
            Main.modulesAtMs = now
            Hooks.installModules()
            ALifeBrain.Standoff.forget(now)
            ALifeBrain.Control.forget(now)
            ALifeBrain.Moods.forget(now)
        end
    end
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
        -- Behavior cloning: watch A-Life's decisions (never changes them).
        local tapped, tapReason = Hooks.installDecisionTap(ALifeBrain.DecisionLog.onDecision)
        log("decision log " .. (tapped and "ready" or "not installed") .. " (" .. tostring(tapReason) .. ")")
        -- Our A-Life modules: hostile NPCs talk before shooting, NPCs warn each other, followers
        -- keep with the player (and sneak when the player sneaks).
        local modules, modulesReason = Hooks.installModules()
        log("A-Life modules " .. (modules and "ready" or "not installed") .. " (" .. tostring(modulesReason) .. ")")
        if modules then Main.modulesAtMs = nowMs() end
        local sneak, sneakReason = Hooks.wrapStealthStance()
        log("followers sneak with the player: " .. tostring(sneak) .. " (" .. tostring(sneakReason) .. ")")
        local loaded, notes = ALifeBrain.DecisionLog.loadPolicy()
        log("policy (shadow mode): " .. (#loaded > 0 and table.concat(loaded, ", ") or "none trained yet")
            .. (#notes > 0 and (" [" .. table.concat(notes, "; ") .. "]") or ""))
        -- Phase 5: with policy control on, the policy picks among A-Life's modules (Control.lua).
        local Control = ALifeBrain.Control
        local chooser = Hooks.setDecisionChooser(Control.pick, Control.onChosen)
        Main.loadOptions()
        log("policy control: " .. (Control.enabled() and "on" or "off") .. " (Mod Options; tap "
            .. (chooser and "ready" or "missing") .. ")")
    end
end

-- Mod Options (B42 PZAPI.ModOptions): one tick box for policy control. The game keeps its
-- value in its own ModOptions.ini; created when this file loads, so the options screen has it.
function Main.createOptions()
    local api = type(PZAPI) == "table" and PZAPI.ModOptions or nil
    if type(api) ~= "table" or type(api.create) ~= "function" then return false, "no_mod_options" end
    local T = ALifeBrain.Text
    local ok, options = pcall(api.create, api, "ALifeBrain", "A-Life Brain")
    if not ok or type(options) ~= "table" then return false, tostring(options) end
    local made, option = pcall(options.addTickBox, options, "policyControl", T.get("option_control"), false,
        T.get("option_control_tip"))
    if not made then return false, tostring(option) end
    Main.options = options
    ALifeBrain.Control.option = option
    return true
end

-- The options screen reads ModOptions.ini only when it is built; read the saved values now.
function Main.loadOptions()
    local api = type(PZAPI) == "table" and PZAPI.ModOptions or nil
    if Main.options == nil or type(api) ~= "table" or type(api.load) ~= "function" then return false end
    return pcall(api.load, api)
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
    local decisions = ALifeBrain.DecisionLog.stats
    status.decisions = { seen = decisions.seen, sampled = decisions.sampled, sent = decisions.sent,
        dropped = decisions.dropped, failed = decisions.failed, queued = #ALifeBrain.DecisionLog.queue,
        tapError = Hooks.decisionTapError, shadow = ALifeBrain.DecisionLog.agreement() }
    status.companion = { regroup = Hooks.companionStats.regroup, fallBack = Hooks.companionStats.fall_back,
        last = Hooks.companionLast }
    status.standoff = ALifeBrain.Standoff.stats
    local parley = ALifeBrain.Parley
    status.parley = { stats = parley.stats, active = parley.active ~= nil and parley.active.uid or nil,
        lastNote = parley.lastNote }
    local control = ALifeBrain.Control
    status.control = { on = control.enabled(), decision = control.stats.decision, response = control.stats.response,
        reasons = control.stats.reasons, chooserError = Hooks.decisionChooserError }
    status.moods = ALifeBrain.Moods.stats
    log(tostring(Json.encode(status)))
    return status
end

-- Debug console: which choices A-Life made most (from the sampled decisions), and how
-- often the trained policy agrees with it in shadow mode.
function ALifeBrain.policy()
    local labels = {}
    for label, count in pairs(ALifeBrain.DecisionLog.stats.labels) do labels[#labels + 1] = { label = label, count = count } end
    table.sort(labels, function(a, b) return a.count > b.count end)
    for index = 1, math.min(#labels, 15) do
        log("  " .. labels[index].label .. " x" .. Json.intToString(labels[index].count))
    end
    for kind, agreement in pairs(ALifeBrain.DecisionLog.agreement()) do
        if agreement.n > 0 then
            log("  shadow " .. kind .. ": agrees " .. Json.intToString(math.floor(agreement.rate * 100 + 0.5))
                .. "% of " .. Json.intToString(agreement.n))
        end
    end
    ALifeBrain.control()
    return ALifeBrain.DecisionLog.agreement()
end

-- Debug console: ALifeBrain.control(true) lets the policy choose for this session, false
-- stops it, "option" follows the Mod Options tick box again; ALifeBrain.control() reports
-- what it chose (ran) and how often A-Life kept the decision (left: why; near: a player).
function ALifeBrain.control(on)
    local Control = ALifeBrain.Control
    if on == "option" then Control.forced = nil elseif on ~= nil then Control.forced = on == true end
    log("policy control " .. (Control.enabled() and "ON" or "off")
        .. (Control.forced ~= nil and " (console)" or " (Mod Options)"))
    for _, kind in ipairs({ "decision", "response" }) do
        local s = Control.stats[kind]
        log("  " .. kind .. ": asked " .. Json.intToString(s.asked) .. ", ran " .. Json.intToString(s.ran)
            .. ", nothing to do " .. Json.intToString(s.declined) .. ", near a player " .. Json.intToString(s.near)
            .. ", left to A-Life " .. Json.intToString(s.left))
    end
    local modules = {}
    for key, count in pairs(Control.stats.modules) do modules[#modules + 1] = { key = key, count = count } end
    table.sort(modules, function(a, b) return a.count > b.count end)
    for index = 1, math.min(#modules, 10) do
        log("  ran " .. modules[index].key .. " x" .. Json.intToString(modules[index].count))
    end
    for reason, count in pairs(Control.stats.reasons) do log("  left to A-Life: " .. reason .. " x" .. Json.intToString(count)) end
    return Control.enabled()
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

Main.createOptions()

if type(Events) == "table" then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(Main.onGameStart) end
    if Events.OnTick ~= nil then Events.OnTick.Add(Main.onTick) end
end

return Main
