-- A-Life crews robbing the player become memories (CLAUDE.md event log: "soyuldu"). A-Life's
-- robbery module (ModuleRobbery) keeps each robbery in a table until it ends; this watches
-- that table now and then (read only, Hooks.activeRobberies) and, for each robbery that has
-- just ended, sends one "robbed_player" event: the crew, how it ended (A-Life's reason:
-- "released" after the player handed things over, "execute:<why>" when the crew opened fire,
-- or it came to nothing) and what was taken. The crew then remembers it in conversation.

ALifeBrain = ALifeBrain or {}

local Robberies = {
    settings = { periodMs = 1000, maxCrew = 6 },
    seen = {},
    lastMs = 0,
    stats = { seen = 0, reported = 0 },
}
ALifeBrain.Robberies = Robberies

-- Tests replace this with fakes: { hooks = ..., emit = function(kind, fields) end }.
Robberies.override = nil

local function deps()
    if Robberies.override ~= nil then return Robberies.override end
    return { hooks = ALifeBrain.Hooks, emit = function(kind, fields) return ALifeBrain.EventLog.emit(kind, fields) end }
end

-- The event for a robbery that ended.
function Robberies.describe(state, d)
    local crew = ALifeBrain.Json ~= nil and ALifeBrain.Json.array({}) or {}
    for _, uid in ipairs(type(state.members) == "table" and state.members or {}) do
        if #crew >= Robberies.settings.maxCrew then break end
        local npc = d.hooks.describeRecord(uid)
        if npc ~= nil then crew[#crew + 1] = npc end
    end
    local taken = ALifeBrain.Json ~= nil and ALifeBrain.Json.array({}) or {}
    for _, fullType in ipairs(type(state.taken) == "table" and state.taken or {}) do
        taken[#taken + 1] = d.hooks.itemName(fullType)
    end
    local leader = d.hooks.describeRecord(state.leaderUid) or crew[1]
    local key = state.player ~= nil and d.hooks.playerKey(state.player) or nil
    return { npc = leader, crew = crew, outcome = tostring(state.finishedReason or "unknown"), taken = taken,
        by = { kind = "player", key = key or state.playerKey } }
end

-- Called every game tick.
function Robberies.tick(now)
    if now - Robberies.lastMs < Robberies.settings.periodMs then return end
    Robberies.lastMs = now
    local d = deps()
    local active = d.hooks.activeRobberies()
    for id, state in pairs(active) do
        if Robberies.seen[id] == nil and type(state) == "table" then
            Robberies.seen[id] = state
            Robberies.stats.seen = Robberies.stats.seen + 1
        end
    end
    for id, state in pairs(Robberies.seen) do
        if active[id] == nil then
            Robberies.seen[id] = nil
            local fields = Robberies.describe(state, d)
            if fields.npc ~= nil and d.emit("robbed_player", fields) then
                Robberies.stats.reported = Robberies.stats.reported + 1
            end
        end
    end
end

return Robberies
