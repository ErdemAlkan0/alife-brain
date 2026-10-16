-- Entry point: starts the sidecar bridge, keeps a ping going, runs the in-game tests
-- in debug mode. Debug console helpers: ALifeBrain.status(), ALifeBrain.ping(),
-- ALifeBrain.runTests(), ALifeBrain.policy(), ALifeBrain.control(on), ALifeBrain.npcs(),
-- ALifeBrain.releaseKept().

require "ALifeBrain/Json"
require "ALifeBrain/Bridge"
require "ALifeBrain/ALifeBrainHooks"
require "ALifeBrain/EventLog"
require "ALifeBrain/Dialogue"
require "ALifeBrain/DecisionLog"
require "ALifeBrain/Moods"
require "ALifeBrain/Control"
require "ALifeBrain/Keeper"
require "ALifeBrain/Rapport"
require "ALifeBrain/Pause"
require "ALifeBrain/Robberies"
require "ALifeBrain/Companion"
require "ALifeBrain/Standoff"
require "ALifeBrain/Parley"
require "ALifeBrain/ChatWindow"
require "ALifeBrain/Tests/AllTests"

ALifeBrain = ALifeBrain or {}
ALifeBrain.VERSION = "0.1.1"

local Json, Bridge, Hooks = ALifeBrain.Json, ALifeBrain.Bridge, ALifeBrain.Hooks

local Main = {
    settings = { pingIntervalMs = 10000, logEveryNthPong = 6, runTestsInDebug = true, modulesRefreshMs = 30000,
        stealthMs = 500, policyStatsMs = 300000 },
    lastPingAtMs = -math.huge,
    policyStatsAtMs = 0,
    policyAsked = 0,
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
        ALifeBrain.Keeper.tick(now)
        ALifeBrain.Rapport.tick(now)
        ALifeBrain.Robberies.tick(now)
        if now - Main.stealthAtMs >= Main.settings.stealthMs then
            Main.stealthAtMs = now
            Hooks.updateFollowerStealth()
        end
        -- Behavior profiles added later (custom factions) get our modules too.
        if now - Main.modulesAtMs >= Main.settings.modulesRefreshMs then
            Main.modulesAtMs = now
            Hooks.installModules()
            ALifeBrain.Standoff.forget(now)
            ALifeBrain.Parley.forget(now)
            ALifeBrain.Control.forget(now)
            ALifeBrain.Moods.forget(now)
        end
        Main.reportPolicy(now)
    end
    if bridge:isOnline() and nowMs() - Main.lastPingAtMs >= Main.settings.pingIntervalMs then
        Main.ping()
    end
end

-- With policy control on, its counters go to the sidecar now and then ("policy_stats": the
-- sidecar log and events.jsonl keep them, so a play session can be read afterwards).
function Main.reportPolicy(now)
    local Control, bridge = ALifeBrain.Control, ALifeBrain.bridge
    if bridge == nil or not bridge:isOnline() or not Control.enabled() then return end
    if now - Main.policyStatsAtMs < Main.settings.policyStatsMs then return end
    Main.policyStatsAtMs = now
    local s = Control.stats
    local asked = s.decision.asked + s.response.asked
    if asked == Main.policyAsked then return end
    Main.policyAsked = asked
    bridge:send("event", { kind = "policy_stats", decision = s.decision, response = s.response, modules = s.modules,
        reasons = s.reasons })
end

-- OnTick stops while the game is paused (the conversation window pauses it, Pause.lua): the
-- bridge and the dialogue keep going here so a reply still reaches the window. The world's
-- own work (A-Life decisions, parleys, keeping NPCs) waits with the game.
function Main.onTickEvenPaused()
    local bridge = ALifeBrain.bridge
    if bridge == nil or not ALifeBrain.Pause.gamePaused() then return end
    bridge:tick()
    ALifeBrain.Dialogue.tick(nowMs())
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
        world = Hooks.worldKey(),
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
        local saved = Main.loadOptions()
        log("policy control: " .. (Control.enabled() and "on" or "off") .. " (Mod Options: saved "
            .. tostring(saved) .. ", menu " .. tostring(Control.option ~= nil) .. "; tap "
            .. (chooser and "ready" or "missing") .. ")")
        local Keeper = ALifeBrain.Keeper
        log("keep NPCs met within " .. Json.intToString(Keeper.settings.tiles) .. " tiles: "
            .. (Keeper.enabled() and "on" or "off") .. "; pause while talking: "
            .. (ALifeBrain.Pause.enabled() and "on" or "off"))
    end
end

-- Mod Options (B42 PZAPI.ModOptions): tick boxes for policy control and keeping met NPCs.
-- The game keeps their values in its own ModOptions.ini; created when this file loads, so the
-- options screen has them.
Main.OPTIONS = {
    { id = "policyControl", owner = "Control", default = false, label = "option_control", tip = "option_control_tip" },
    { id = "keepMetNpcs", owner = "Keeper", default = true, label = "option_keep", tip = "option_keep_tip" },
    { id = "pauseWhileTalking", owner = "Pause", default = true, label = "option_pause", tip = "option_pause_tip" },
}

function Main.createOptions()
    local api = type(PZAPI) == "table" and PZAPI.ModOptions or nil
    if type(api) ~= "table" or type(api.create) ~= "function" then return false, "no_mod_options" end
    local T = ALifeBrain.Text
    local ok, options = pcall(api.create, api, "ALifeBrain", "A-Life Brain")
    if not ok or type(options) ~= "table" then return false, tostring(options) end
    for _, spec in ipairs(Main.OPTIONS) do
        local made, option = pcall(options.addTickBox, options, spec.id, T.get(spec.label), spec.default, T.get(spec.tip))
        if not made then return false, tostring(option) end
        ALifeBrain[spec.owner].option = option
    end
    Main.options = options
    return true
end

-- One of our values as ModOptions.ini has it ("tickbox|ALifeBrain|<id>|true"), or nil. The
-- game writes CRLF lines; a "\r" left on "true" makes its own loader skip the value.
function Main.savedOption(id)
    local value = nil
    pcall(function()
        local reader = getFileReader("ModOptions.ini", false)
        if reader == nil then return end
        while true do
            local line = reader:readLine()
            if line == nil then break end
            local mod, key, raw = string.match(line, "^[^|]*|([^|]*)|([^|]*)|(%a*)")
            if mod == "ALifeBrain" and key == id then
                if raw == "true" then value = true elseif raw == "false" then value = false end
            end
        end
        reader:close()
    end)
    return value
end

-- The options screen reads ModOptions.ini only when it is built; read the saved values now.
-- Play test (2026-10-11): ticked in Mod Options, still "off" in game, so our own line is read
-- as well and wins when the game's loader left the default.
function Main.loadOptions()
    local api = type(PZAPI) == "table" and PZAPI.ModOptions or nil
    if Main.options ~= nil and type(api) == "table" and type(api.load) == "function" then pcall(api.load, api) end
    local values = {}
    for _, spec in ipairs(Main.OPTIONS) do
        local owner = ALifeBrain[spec.owner]
        local saved = Main.savedOption(spec.id)
        owner.saved, values[spec.id] = saved, saved
        if saved ~= nil and owner.option ~= nil and type(owner.option.setValue) == "function" then
            pcall(owner.option.setValue, owner.option, saved)
        end
    end
    return values.policyControl, values
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
    local keeper = ALifeBrain.Keeper
    status.keeper = { on = keeper.enabled(), stats = keeper.stats, savedGroups = keeper.groups, cap = keeper.cap }
    status.rapport = ALifeBrain.Rapport.stats
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
-- ALifeBrain.spawnTestNpc("alife_hobbs", 3) spawns three Hobbs Brothers (hostile). They are kept
-- across saves; pass temporary = true for A-Life's expendable debug NPCs (deleted once nobody
-- visits them for its "Unvisited NPC lifetime").
function ALifeBrain.spawnTestNpc(factionId, count, encounterId, temporary)
    local faction = factionId or "alife_church_volunteers"
    local ok, reason = Hooks.spawnTestNpc(getPlayer(), encounterId or "patrol", count or 1, 6, faction, temporary ~= true)
    log(ok and ("spawn requested (" .. faction .. (temporary == true and ", temporary" or ", kept") .. ")"
        .. "; A-Life answers in its own log") or ("spawn failed: " .. tostring(reason)))
    return ok
end

-- Debug console: A-Life's NPCs (nearest first: lifecycle, kept or expendable, distance) and
-- what its lifecycle telemetry recorded since this load (deletions and their reasons).
-- "dormant" NPCs are stored, not deleted: A-Life brings them back within 60 tiles.
function ALifeBrain.npcs(limit)
    local rows, counts = Hooks.actorSnapshot(getPlayer())
    local summary = {}
    for lifecycle, count in pairs(counts) do summary[#summary + 1] = lifecycle .. " " .. Json.intToString(count) end
    table.sort(summary)
    log("A-Life NPCs: " .. (#summary > 0 and table.concat(summary, ", ") or "none"))
    for index = 1, math.min(#rows, tonumber(limit) or 20) do
        local row = rows[index]
        log("  " .. tostring(row.name or row.uid) .. " [" .. tostring(row.faction) .. "] " .. row.lifecycle
            .. (row.kept and ", kept" or ", expendable") .. (row.debug and " (debug spawn)" or "")
            .. (row.distance ~= nil and (", " .. Json.intToString(math.floor(row.distance + 0.5)) .. " tiles") or ""))
    end
    local groups, cap, ours = Hooks.savedGroups()
    local keeper = ALifeBrain.Keeper
    log("saved groups: " .. Json.intToString(groups) .. " (we kept " .. Json.intToString(ours) .. "), A-Life saves "
        .. tostring(cap) .. "; keeping met NPCs " .. (keeper.enabled() and "on" or "off") .. ", this session "
        .. Json.intToString(keeper.stats.kept) .. " groups / " .. Json.intToString(keeper.stats.npcs) .. " NPCs")
    local events, totals = Hooks.lifecycleEvents()
    local parts = {}
    for category, count in pairs(totals) do
        if count > 0 then parts[#parts + 1] = category .. " " .. Json.intToString(count) end
    end
    log("since this load: " .. (#parts > 0 and table.concat(parts, ", ") or "no deletions or failed spawns"))
    for index = math.max(1, #events - 9), #events do
        local event = events[index]
        log("  " .. tostring(event.category) .. " uid=" .. tostring(event.uid) .. " reason="
            .. tostring(event.reason or event.stage or event.error))
    end
    return rows
end

-- Debug console: trust and A-Life's stance toward the player of every NPC we know a mood of
-- (most trusting first); "trusted" = a careful group that lets the player close (Rapport.lua).
function ALifeBrain.trust(limit)
    local player, now, rows = getPlayer(), nowMs(), {}
    for uid, mind in pairs(ALifeBrain.Dialogue.minds) do
        local record = Hooks.peekRecord(uid)
        if record ~= nil and record.lifecycle ~= "dead" then
            rows[#rows + 1] = { name = Hooks.nameOf(record) or uid, trust = tonumber(mind.trust) or 0,
                fear = tonumber(mind.fear) or 0, stance = ALifeBrain.Chat.stanceOf(record, player) }
        end
    end
    table.sort(rows, function(a, b) return a.trust > b.trust end)
    local settings = ALifeBrain.Rapport.settings
    log("trust lets a careful group's guard down at " .. Json.intToString(settings.trust) .. " (back below "
        .. Json.intToString(settings.keepTrust) .. "); " .. Json.intToString(#rows) .. " NPCs known")
    for index = 1, math.min(#rows, tonumber(limit) or 20) do
        local row = rows[index]
        log("  " .. tostring(row.name) .. ": trust " .. Json.intToString(row.trust) .. ", fear "
            .. Json.intToString(row.fear) .. ", " .. row.stance)
    end
    return rows
end

-- Debug console: undoes keeping for every NPC we kept (turn "Keep NPCs you meet" off in Mod
-- Options first, or the next meeting keeps them again).
function ALifeBrain.releaseKept()
    local released = ALifeBrain.Keeper.releaseAll()
    log("released " .. Json.intToString(released) .. " kept NPCs (A-Life treats them as before)")
    return released
end

function ALifeBrain.runTests()
    return ALifeBrain.Tests.runAll(log)
end

Main.createOptions()

if type(Events) == "table" then
    if Events.OnGameStart ~= nil then Events.OnGameStart.Add(Main.onGameStart) end
    if Events.OnTick ~= nil then Events.OnTick.Add(Main.onTick) end
    if Events.OnTickEvenPaused ~= nil then Events.OnTickEvenPaused.Add(Main.onTickEvenPaused) end
end

return Main
