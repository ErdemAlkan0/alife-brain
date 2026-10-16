-- Logs game events involving A-Life NPCs and sends them to the sidecar as "event"
-- messages. They become NPC memories (phase 2) and RL training data (phase 3).
-- Only vanilla events are used here; A-Life specifics go through ALifeBrainHooks.

require "ALifeBrain/ALifeBrainHooks"

ALifeBrain = ALifeBrain or {}

local Hooks = ALifeBrain.Hooks

local EventLog = {
    settings = {
        enabled = true,
        hitRepeatMs = 750,
        helpTiles = 10, -- an NPC this close to a zombie the player kills saw the player fight for it
        helpRepeatMs = 60000, -- per NPC: kills in between are added up into the next event
        friendlyFireTiles = 4, -- a player's hit on an NPC with the dead this close was likely meant for them
    },
    lastHitAtMs = {},
    lastHelpAtMs = {},
    helpKills = {},
    metrics = { hits = 0, deaths = 0, throttled = 0, refused = 0, helped = 0 },
}
ALifeBrain.EventLog = EventLog

local function nowMs()
    if type(getTimestampMs) == "function" then return getTimestampMs() end
    return math.floor(os.time() * 1000)
end

local function position(object)
    local ok, x, y, z = pcall(function() return object:getX(), object:getY(), object:getZ() end)
    if not ok or x == nil then return nil end
    return { x = math.floor(x * 10) / 10, y = math.floor(y * 10) / 10, z = math.floor(z) }
end

local function fullType(item)
    if item == nil then return nil end
    local ok, value = pcall(function() return item:getFullType() end)
    return ok and value or nil
end

-- Describes whoever caused an event: a player, another A-Life NPC, or a plain zombie.
-- named: also the NPC's name, faction and squad (deaths only: hits come in every swing). The
-- sidecar then remembers who really killed a squad mate instead of an unexplained loss the
-- LLM filled in with the player (play test, 2026-10-11).
local function actorRef(object, named)
    if object == nil then return nil end
    if Hooks.isPlayer(object) then return { kind = "player", key = Hooks.playerKey(object) } end
    local uid = Hooks.identity(object)
    if uid ~= nil then
        local ref = { kind = "npc", uid = uid }
        local info = named and Hooks.describe(object) or nil
        if info ~= nil then ref.name, ref.factionId, ref.groupId = info.name, info.factionId, info.groupId end
        return ref
    end
    local ok, zombie = pcall(function() return instanceof(object, "IsoZombie") end)
    if ok and zombie then return { kind = "zombie" } end
    return { kind = "other" }
end

-- Events by the player that move the NPCs' trust or fear in the sidecar (experience.py): the
-- game then asks for their moods again (Moods.refresh).
EventLog.MOOD_EVENTS = { npc_hit = true, player_helped = true, robbed_player = true }

local function refreshMoods(kind, fields)
    local moods = ALifeBrain.Moods
    if moods == nil or not EventLog.MOOD_EVENTS[kind] or type(fields.by) ~= "table" or fields.by.kind ~= "player" then
        return
    end
    if type(fields.npc) == "table" then moods.refresh(fields.npc.uid) end
    for _, member in ipairs(type(fields.crew) == "table" and fields.crew or {}) do
        if type(member) == "table" then moods.refresh(member.uid) end
    end
end

function EventLog.emit(kind, fields)
    if EventLog.settings.enabled ~= true then return false end
    local bridge = ALifeBrain.bridge
    if bridge == nil then return false end
    fields = fields or {}
    fields.kind = kind
    local ok = bridge:send("event", fields)
    if not ok then EventLog.metrics.refused = EventLog.metrics.refused + 1 end
    if ok then refreshMoods(kind, fields) end
    return ok
end

-- Events.OnHitZombie(zombie, attacker, bodyPartType, weapon)
function EventLog.onHitZombie(zombie, attacker, bodyPartType, weapon)
    if not Hooks.isNpc(zombie) then return end
    local npc = Hooks.describe(zombie)
    if npc == nil then return end
    local now = nowMs()
    -- Hitting one of a crew that is talking ends the talk (Parley.lua).
    if Hooks.isPlayer(attacker) and ALifeBrain.Parley ~= nil then pcall(ALifeBrain.Parley.onPlayerAttack, npc.uid, now) end
    if now - (EventLog.lastHitAtMs[npc.uid] or -math.huge) < EventLog.settings.hitRepeatMs then
        EventLog.metrics.throttled = EventLog.metrics.throttled + 1
        return
    end
    EventLog.lastHitAtMs[npc.uid] = now
    EventLog.metrics.hits = EventLog.metrics.hits + 1
    -- Shooting the dead around an NPC hits it now and then (shotgun spread): the sidecar takes
    -- that as an accident, not an attack (play test, 2026-10-11: guards at -11 trust from one shot).
    local zombiesNear = nil
    if Hooks.isPlayer(attacker) then zombiesNear = Hooks.zombiesNear(zombie, EventLog.settings.friendlyFireTiles) end
    EventLog.emit("npc_hit", {
        npc = npc,
        by = actorRef(attacker),
        weapon = fullType(weapon),
        bodyPart = bodyPartType ~= nil and tostring(bodyPartType) or nil,
        pos = position(zombie),
        zombiesNear = zombiesNear,
    })
end

-- A plain zombie the player killed: the A-Life NPCs right there saw the player fight the dead
-- beside them ("player_helped"), so they can remember it and trust grows (play test,
-- 2026-10-11: "I saved you" earned only "prove it", nothing had recorded it). Per NPC at most
-- one event per helpRepeatMs; the kills in between are counted into the next one.
function EventLog.onZombieKilled(zombie)
    local killer = nil
    pcall(function() killer = zombie:getAttackedBy() end)
    if killer == nil or not Hooks.isPlayer(killer) then return end
    local settings, now = EventLog.settings, nowMs()
    for _, body in ipairs(Hooks.npcBodiesNear(zombie, settings.helpTiles, 6)) do
        local uid = Hooks.identity(body)
        if uid ~= nil then
            local kills = (EventLog.helpKills[uid] or 0) + 1
            EventLog.helpKills[uid] = kills
            if now - (EventLog.lastHelpAtMs[uid] or -math.huge) >= settings.helpRepeatMs then
                local npc = Hooks.describe(body)
                if npc ~= nil then
                    EventLog.lastHelpAtMs[uid], EventLog.helpKills[uid] = now, 0
                    EventLog.metrics.helped = EventLog.metrics.helped + 1
                    EventLog.emit("player_helped", { npc = npc, by = actorRef(killer), kills = kills, pos = position(zombie) })
                end
            end
        end
    end
end

-- Events.OnZombieDead(zombie). A-Life may already have turned the body into a corpse
-- (ProjectALifeOwned cleared, ProjectALifeCorpseOf set) before this runs.
function EventLog.onZombieDead(zombie)
    if not (Hooks.isNpc(zombie) or Hooks.isNpcCorpse(zombie)) then return EventLog.onZombieKilled(zombie) end
    local npc = Hooks.describe(zombie)
    if npc == nil then return end
    EventLog.lastHitAtMs[npc.uid] = nil
    local killer = nil
    pcall(function() killer = zombie:getAttackedBy() end)
    EventLog.metrics.deaths = EventLog.metrics.deaths + 1
    EventLog.emit("npc_died", {
        npc = npc,
        by = actorRef(killer, true),
        pos = position(zombie),
    })
end

if type(Events) == "table" then
    if Events.OnHitZombie ~= nil then Events.OnHitZombie.Add(EventLog.onHitZombie) end
    if Events.OnZombieDead ~= nil then Events.OnZombieDead.Add(EventLog.onZombieDead) end
end

return EventLog
