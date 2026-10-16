-- Stored moods for the policy (phase 5). Trust / fear toward the player and the drive of
-- NPCs not talked to in this session live in the sidecar's memory. When the policy (or the
-- decision log) meets such an NPC its uid is queued, and a "moods" request now and then
-- fetches a batch (docs/bridge-protocol.md) into Dialogue.minds. NPCs the sidecar knows
-- nothing about come back empty and stay at 0; they are asked again after retryMs.
-- Moods.refresh asks again for a known NPC after an event moved its trust in the sidecar.

require "ALifeBrain/Json"
require "ALifeBrain/Dialogue"

ALifeBrain = ALifeBrain or {}

local Moods = {
    settings = {
        batch = 24, -- uids per request (the sidecar answers at most 32)
        periodMs = 3000, -- at most one request this often
        retryMs = 300000, -- an NPC that came back empty is asked again after this long
        timeoutMs = 8000,
        maxWanted = 200,
    },
    wanted = {},
    order = {},
    askedAtMs = {},
    refreshing = {}, -- uids asked again although their mind is known
    inflight = false,
    lastSentMs = 0,
    stats = { asked = 0, filled = 0, failed = 0 },
}
ALifeBrain.Moods = Moods

-- Tests replace this with fakes: { bridge = ..., hooks = ..., player = ... }.
Moods.override = nil

local function deps()
    if Moods.override ~= nil then return Moods.override end
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(0) or nil
    return { bridge = ALifeBrain.bridge, hooks = ALifeBrain.Hooks, player = player }
end

function Moods.reset()
    Moods.wanted, Moods.order, Moods.askedAtMs, Moods.refreshing = {}, {}, {}, {}
    Moods.inflight, Moods.lastSentMs = false, 0
    Moods.stats = { asked = 0, filled = 0, failed = 0 }
end

function Moods.supported(bridge)
    return bridge ~= nil and bridge:isOnline() and type(bridge.features) == "table" and bridge.features.moods == true
end

-- Queues an NPC whose mind we do not know yet. Cheap: called on every decision.
function Moods.want(uid, now)
    if type(uid) ~= "string" or Moods.wanted[uid] or ALifeBrain.Dialogue.minds[uid] ~= nil then return end
    local asked = Moods.askedAtMs[uid]
    if asked ~= nil and now - asked < Moods.settings.retryMs then return end
    if #Moods.order >= Moods.settings.maxWanted then return end
    Moods.wanted[uid] = true
    Moods.order[#Moods.order + 1] = uid
end

-- An event just moved this NPC's trust or fear in the sidecar (a gift, a fair trade, help against
-- the dead, a hit, a robbery; EventLog.MOOD_EVENTS, Dialogue.report): asks again although its
-- mind is known, so trust earned by deeds counts (Rapport.lua, the policy) before the next
-- conversation. Play test (2026-10-12): a gift took Henry's trust to 13 in the sidecar while
-- the game still read the 7 of his last reply.
function Moods.refresh(uid)
    if type(uid) ~= "string" then return end
    Moods.refreshing[uid] = true
    if Moods.wanted[uid] or #Moods.order >= Moods.settings.maxWanted then return end
    Moods.wanted[uid] = true
    Moods.order[#Moods.order + 1] = uid
end

-- Called every game tick: sends one batch when there is one and the sidecar can answer.
function Moods.tick(now)
    if Moods.inflight or #Moods.order == 0 or now - Moods.lastSentMs < Moods.settings.periodMs then return end
    local d = deps()
    if not Moods.supported(d.bridge) then return end
    local key = d.player ~= nil and d.hooks.playerKey(d.player) or nil
    if key == nil then return end
    local minds = ALifeBrain.Dialogue.minds
    local uids, refreshed = ALifeBrain.Json.array({}), {}
    while #uids < Moods.settings.batch and #Moods.order > 0 do
        local uid = table.remove(Moods.order, 1)
        Moods.wanted[uid] = nil
        if minds[uid] == nil or Moods.refreshing[uid] then
            uids[#uids + 1] = uid
            refreshed[uid] = Moods.refreshing[uid]
            Moods.refreshing[uid] = nil
            Moods.askedAtMs[uid] = now
        end
    end
    if #uids == 0 then return end
    Moods.lastSentMs = now
    local id = d.bridge:request("moods", { playerKey = key, uids = uids }, function(ok, data)
        Moods.inflight = false
        if not ok or type(data) ~= "table" or type(data.moods) ~= "table" then
            Moods.stats.failed = Moods.stats.failed + 1
            return
        end
        local at, Dialogue = d.hooks.nowMs(), ALifeBrain.Dialogue
        for _, mood in ipairs(data.moods) do
            local apply = type(mood) == "table" and refreshed[mood.uid] and Dialogue.updateMood or Dialogue.learnMood
            if type(mood) == "table" and apply(mood.uid, mood, at) then
                Moods.stats.filled = Moods.stats.filled + 1
            end
        end
    end, Moods.settings.timeoutMs)
    if id ~= nil then
        Moods.inflight = true
        Moods.stats.asked = Moods.stats.asked + #uids
    else
        Moods.stats.failed = Moods.stats.failed + 1
    end
end

-- Drops what it remembers about asking (called now and then).
function Moods.forget(now)
    for uid, at in pairs(Moods.askedAtMs) do
        if now - at >= Moods.settings.retryMs then Moods.askedAtMs[uid] = nil end
    end
end

return Moods
