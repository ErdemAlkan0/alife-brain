-- Combat discipline for NPCs following a player. A-Life answers every threat it perceives
-- the same way (engage), whatever the NPC is doing, and a follow order has no leash: a
-- follower chased every zombie it saw and walked into crowds (user report, 2026-10-09:
-- Grace, a melee volunteer, charged 25 zombies and died). This decides, for a follower
-- facing zombies, whether to leave it to A-Life (fight), go back to the player, or fall
-- back. Hooks.installCompanionModule runs it as an A-Life "response" module, between
-- A-Life's own flee and panic. People threats and NPCs not following stay A-Life's.
--
-- When the player sneaks, the follower sneaks too (Hooks.wrapStealthStance: crouched,
-- slower, no running) and leaves zombies alone unless one is right on it or the player:
-- running after the player in bursts drew zombies (user report, same day).

ALifeBrain = ALifeBrain or {}

local Companion = {
    MODULE_ID = "alifeBrainCompanion",
    settings = {
        leashTiles = 8, -- fight only zombies this close to the player; farther ones are not chased
        crowdRadius = 4, -- zombies this close to the NPC count as on top of it
        crowdMelee = 3, -- that many on top of a melee fighter (or an unarmed one) is too many
        crowdFirearm = 6,
        woundedHealth = 0.5, -- below this, any zombie on top of it means falling back
        fallBackMs = 5000, -- keep falling back this long, so it does not flip back and forth
        besideTiles = 2.5, -- this close to the player counts as beside them
        sneakIgnoreTiles = 3, -- sneaking: zombies farther than this from the NPC and the player are left alone
        dangerTiles = 2, -- a zombie this close is worth running from, even when sneaking
        catchUpTiles = 6, -- farther than this from a walking player: run to catch up
    },
    fallingBack = {},
    sneakers = {}, -- uid -> true while the player it follows sneaks
}
ALifeBrain.Companion = Companion

-- view: { following, threatKind, threatFromPlayer, threatFromNpc, npcFromPlayer, closeZombies,
--         firearm, health, sneaking, playerRunning }
-- Returns nil (A-Life decides; it will fight), "regroup" (go back to the player, ignore this
-- zombie; stay put when already beside them) or "fall_back" (get away from the zombies).
function Companion.decide(view, uid, now)
    if type(view) ~= "table" or view.following ~= true or view.threatKind ~= "zombie" then return nil end
    local settings = Companion.settings
    local close = tonumber(view.closeZombies) or 0
    local crowd = view.firearm == true and settings.crowdFirearm or settings.crowdMelee
    local hurt = (tonumber(view.health) or 1) < settings.woundedHealth and close >= 1
    if close >= crowd or hurt then
        Companion.fallingBack[uid] = now + settings.fallBackMs
        return "fall_back"
    end
    local until_ = Companion.fallingBack[uid]
    if until_ ~= nil and now < until_ then return "fall_back" end
    Companion.fallingBack[uid] = nil
    if view.sneaking == true then
        local nearest = math.min(tonumber(view.threatFromNpc) or math.huge, tonumber(view.threatFromPlayer) or math.huge)
        if nearest > settings.sneakIgnoreTiles then return "regroup" end
        return nil
    end
    if (tonumber(view.threatFromPlayer) or 0) > settings.leashTiles then return "regroup" end
    return nil
end

-- Where falling back goes: to the player when they are clear of the zombies, else away
-- from the zombies.
function Companion.fallBackTo(view)
    local clear = (tonumber(view.threatFromPlayer) or 0) > Companion.settings.crowdRadius + 2
    return clear and "player" or "away"
end

-- "walk" or "run" for the move that action starts. Sneaking means walking (crouched),
-- unless a zombie is right on the NPC; otherwise keep the player's pace when close.
function Companion.pace(view, action)
    local settings = Companion.settings
    local danger = (tonumber(view.threatFromNpc) or math.huge) <= settings.dangerTiles
    if view.sneaking == true then return danger and "run" or "walk" end
    if action == "fall_back" or danger or view.playerRunning == true then return "run" end
    return (tonumber(view.npcFromPlayer) or 0) > settings.catchUpTiles and "run" or "walk"
end

-- Followers whose player sneaks right now: { uid = true }. orders: DecisionLoop.orders;
-- sneaking(player) tells whether that player sneaks.
function Companion.refreshSneakers(orders, sneaking)
    local found = {}
    for uid, order in pairs(type(orders) == "table" and orders or {}) do
        if type(order) == "table" and order.kind == "follow" and order.source ~= "leader" and order.player ~= nil
                and sneaking(order.player) then
            found[uid] = true
        end
    end
    Companion.sneakers = found
    return found
end

return Companion
