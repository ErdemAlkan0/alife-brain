-- Keeps the NPCs the player has met. An A-Life NPC that comes within settings.tiles of a
-- player is kept together with its group (Hooks.keepGroupOf): A-Life then writes it into
-- the save and never deletes it as an unvisited NPC. A-Life on its own saves only
-- persistent groups (outposts, persistent encounters, its offline squads); everyone else
-- lived for one session, so the NPCs a player had talked to were gone after reloading
-- (user request, 2026-10-11). The player moving away later changes nothing.
--
-- On by default; the Mod Options tick box stops keeping new ones, ALifeBrain.releaseKept()
-- undoes it. A-Life still saves at most its sandbox "Saved group limit" (default 20) of
-- these groups: a warning shows when the kept ones go past it.

ALifeBrain = ALifeBrain or {}

local Keeper = {
    settings = {
        tiles = 10,
        periodMs = 2000,
        retryMs = 30000, -- a failed write is tried again after this long
    },
    option = nil, -- PZAPI.ModOptions tick box (client)
    saved = nil, -- its value in ModOptions.ini, used when there is no tick box
    done = {},
    lastMs = 0,
    warnedCap = false,
    groups = nil,
    cap = nil,
    stats = nil,
}
ALifeBrain.Keeper = Keeper

-- Tests replace this with fakes: { hooks = ..., warn = function(text) end }.
Keeper.override = nil

local function deps()
    if Keeper.override ~= nil then return Keeper.override end
    local hooks = ALifeBrain.Hooks
    return {
        hooks = hooks,
        warn = function(text)
            print("[ALifeBrain] " .. text)
            local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(0) or nil
            if player ~= nil then hooks.notify(player, text, false) end
        end,
    }
end

function Keeper.reset()
    Keeper.done, Keeper.lastMs, Keeper.warnedCap = {}, 0, false
    Keeper.groups, Keeper.cap = nil, nil
    Keeper.stats = { kept = 0, npcs = 0, already = 0, managed = 0, failed = 0 }
end
Keeper.reset()

function Keeper.enabled()
    local option = Keeper.option
    if option ~= nil and type(option.getValue) == "function" then
        local ok, value = pcall(option.getValue, option)
        return not ok or value ~= false
    end
    return Keeper.saved ~= false
end

-- Warns once a session when A-Life would leave kept groups out of the save.
function Keeper.checkCap(d)
    local groups, cap = d.hooks.savedGroups()
    Keeper.groups, Keeper.cap = groups, cap
    if cap == nil or groups <= cap or Keeper.warnedCap then return end
    Keeper.warnedCap = true
    local text = ALifeBrain.Text ~= nil and ALifeBrain.Text.get("keep_cap", { groups = groups, cap = cap })
        or ("A-Life saves " .. tostring(cap) .. " of " .. tostring(groups) .. " kept groups")
    pcall(d.warn, text)
end

-- Called every game tick.
function Keeper.tick(now)
    if now - Keeper.lastMs < Keeper.settings.periodMs or not Keeper.enabled() then return end
    Keeper.lastMs = now
    local d = deps()
    local stats, keptAny = Keeper.stats, false
    for _, uid in ipairs(d.hooks.actorsNearPlayers(Keeper.settings.tiles)) do
        local state = Keeper.done[uid]
        if state == nil or (state ~= true and now >= state) then
            local result, detail = d.hooks.keepGroupOf(uid, now)
            if result == "kept" then
                stats.kept = stats.kept + 1
                stats.npcs = stats.npcs + (tonumber(detail) or 1)
                keptAny = true
                Keeper.done[uid] = true
            elseif result == "already" or result == "managed" then
                stats[result] = stats[result] + 1
                Keeper.done[uid] = true
            elseif detail == "dead" or detail == "unknown" then
                Keeper.done[uid] = true
            else
                stats.failed = stats.failed + 1
                Keeper.done[uid] = now + Keeper.settings.retryMs
            end
        end
    end
    if keptAny then Keeper.checkCap(d) end
end

-- Undoes it for every NPC we kept (A-Life's own persistent ones stay as they were). Returns
-- how many were released; turn the option off first, or the next meeting keeps them again.
function Keeper.releaseAll()
    local released = deps().hooks.releaseKept()
    Keeper.done = {}
    return released
end

return Keeper
