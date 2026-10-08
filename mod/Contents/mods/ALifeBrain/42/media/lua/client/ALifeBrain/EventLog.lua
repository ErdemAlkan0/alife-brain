-- Logs game events involving A-Life NPCs and sends them to the sidecar as "event"
-- messages. They become NPC memories (phase 2) and RL training data (phase 3).
-- Only vanilla events are used here; A-Life specifics go through ALifeBrainHooks.

require "ALifeBrain/ALifeBrainHooks"

ALifeBrain = ALifeBrain or {}

local Hooks = ALifeBrain.Hooks

local EventLog = {
    settings = { enabled = true, hitRepeatMs = 750 },
    lastHitAtMs = {},
    metrics = { hits = 0, deaths = 0, throttled = 0, refused = 0 },
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
local function actorRef(object)
    if object == nil then return nil end
    if Hooks.isPlayer(object) then return { kind = "player", key = Hooks.playerKey(object) } end
    local uid = Hooks.identity(object)
    if uid ~= nil then return { kind = "npc", uid = uid } end
    local ok, zombie = pcall(function() return instanceof(object, "IsoZombie") end)
    if ok and zombie then return { kind = "zombie" } end
    return { kind = "other" }
end

function EventLog.emit(kind, fields)
    if EventLog.settings.enabled ~= true then return false end
    local bridge = ALifeBrain.bridge
    if bridge == nil then return false end
    fields = fields or {}
    fields.kind = kind
    local ok = bridge:send("event", fields)
    if not ok then EventLog.metrics.refused = EventLog.metrics.refused + 1 end
    return ok
end

-- Events.OnHitZombie(zombie, attacker, bodyPartType, weapon)
function EventLog.onHitZombie(zombie, attacker, bodyPartType, weapon)
    if not Hooks.isNpc(zombie) then return end
    local npc = Hooks.describe(zombie)
    if npc == nil then return end
    local now = nowMs()
    if now - (EventLog.lastHitAtMs[npc.uid] or -math.huge) < EventLog.settings.hitRepeatMs then
        EventLog.metrics.throttled = EventLog.metrics.throttled + 1
        return
    end
    EventLog.lastHitAtMs[npc.uid] = now
    EventLog.metrics.hits = EventLog.metrics.hits + 1
    EventLog.emit("npc_hit", {
        npc = npc,
        by = actorRef(attacker),
        weapon = fullType(weapon),
        bodyPart = bodyPartType ~= nil and tostring(bodyPartType) or nil,
        pos = position(zombie),
    })
end

-- Events.OnZombieDead(zombie). A-Life may already have turned the body into a corpse
-- (ProjectALifeOwned cleared, ProjectALifeCorpseOf set) before this runs.
function EventLog.onZombieDead(zombie)
    if not (Hooks.isNpc(zombie) or Hooks.isNpcCorpse(zombie)) then return end
    local npc = Hooks.describe(zombie)
    if npc == nil then return end
    EventLog.lastHitAtMs[npc.uid] = nil
    local killer = nil
    pcall(function() killer = zombie:getAttackedBy() end)
    EventLog.metrics.deaths = EventLog.metrics.deaths + 1
    EventLog.emit("npc_died", {
        npc = npc,
        by = actorRef(killer),
        pos = position(zombie),
    })
end

if type(Events) == "table" then
    if Events.OnHitZombie ~= nil then Events.OnHitZombie.Add(EventLog.onHitZombie) end
    if Events.OnZombieDead ~= nil then Events.OnZombieDead.Add(EventLog.onZombieDead) end
end

return EventLog
