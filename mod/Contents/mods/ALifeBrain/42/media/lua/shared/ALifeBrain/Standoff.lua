-- Warnings between NPCs before they shoot. A-Life's careful ladder (warn, warn again closer,
-- turn hostile) exists for players only (ModuleCareful.evaluateActor answers nil); two NPCs
-- whose factions are at odds opened fire on sight (user report, 2026-10-09: a careful NPC
-- shot the player's follower without a word). This is the same ladder for an NPC facing
-- another NPC: hold and warn, warn again when it comes closer or stays too long, then let
-- A-Life fight. Anyone who attacks skips the ladder. Hooks.standoffEvaluate runs it as an
-- A-Life "response" module.
--
-- Nobody stares forever: two NPCs that keep their distance part ways and ignore each other
-- for a while (A-Life's Perception.ignore; being attacked clears it), and one too far away to
-- warn is ignored for a moment. Without that, NPCs that kept 15-25 tiles apart stood frozen
-- for up to an hour and a half (play test, 2026-10-10).

ALifeBrain = ALifeBrain or {}

local Standoff = {
    MODULE_ID = "alifeBrainStandoff",
    settings = {
        warnTiles = 25, -- beyond this nobody is warned: the other one is ignored for a moment
        closeTiles = 12, -- coming this close after a warning earns the last warning
        contactTiles = 7, -- this close after the last warning: fight
        graceMs = 4000, -- time to react between two steps
        patienceMs = 14000, -- staying within range this long also climbs a step
        standMs = 25000, -- held their ground this long, nobody closer than closeTiles: they part
        farIgnoreMs = 20000, -- out of warning range: ignored this long, then looked at again
        keepApartMs = 180000, -- parted: they ignore each other this long
        fightMs = 90000, -- once fighting, no new warnings for this long
        forgetMs = 30000, -- not seen for this long: start over
    },
    ladders = {},
    stats = { warnings = 0, lastWarnings = 0, fights = 0, attacked = 0, parted = 0 },
}
ALifeBrain.Standoff = Standoff

-- key: "<uid>><target uid>"; view: { distance, attacked }. Returns the step to take:
-- "warn" | "last_warning" | "hold" | "fight" | "ignore", the A-Life voice event to play on a
-- new step (or nil), and for "ignore" how long (ms) to ignore the other one.
function Standoff.step(key, view, now)
    local settings = Standoff.settings
    local ladder = Standoff.ladders[key]
    if ladder ~= nil and ladder.step < 3 and now - ladder.seenMs > settings.forgetMs then ladder = nil end
    if ladder ~= nil and ladder.step >= 3 then
        if now - ladder.atMs < settings.fightMs then
            ladder.seenMs = now
            return "fight"
        end
        ladder = nil
    end
    if view.attacked == true then
        Standoff.ladders[key] = { step = 3, atMs = now, seenMs = now, startedMs = now }
        Standoff.stats.attacked = Standoff.stats.attacked + 1
        return "fight"
    end
    local distance = tonumber(view.distance) or math.huge
    if ladder == nil then
        if distance > settings.warnTiles then return "ignore", nil, settings.farIgnoreMs end
        Standoff.ladders[key] = { step = 1, atMs = now, seenMs = now, startedMs = now }
        Standoff.stats.warnings = Standoff.stats.warnings + 1
        return "warn", "CAREFUL_KEEP_BACK"
    end
    ladder.seenMs = now
    local waited = now - ladder.atMs -- time on this step
    if ladder.step == 1 and waited >= settings.graceMs
            and (distance <= settings.closeTiles or (waited >= settings.patienceMs and distance <= settings.warnTiles)) then
        ladder.step, ladder.atMs = 2, now
        Standoff.stats.lastWarnings = Standoff.stats.lastWarnings + 1
        return "last_warning", "CAREFUL_LAST_WARNING"
    end
    if ladder.step == 2 and waited >= settings.graceMs
            and (distance <= settings.contactTiles or (waited >= settings.patienceMs and distance <= settings.closeTiles)) then
        ladder.step, ladder.atMs = 3, now
        Standoff.stats.fights = Standoff.stats.fights + 1
        return "fight", "CAREFUL_HOSTILE"
    end
    -- Warned, and nobody came closer: they keep apart instead of staring each other down.
    if now - ladder.startedMs >= settings.standMs and distance > settings.closeTiles then
        Standoff.ladders[key] = nil
        Standoff.stats.parted = Standoff.stats.parted + 1
        return "ignore", nil, settings.keepApartMs
    end
    if distance > settings.warnTiles then return "ignore", nil, settings.farIgnoreMs end -- backed off
    return "hold"
end

-- True while this NPC is on a warning ladder with another NPC (looked at within graceMs).
function Standoff.involves(uid, now)
    local prefix = tostring(uid) .. ">"
    for key, ladder in pairs(Standoff.ladders) do
        if string.sub(key, 1, #prefix) == prefix and now - ladder.seenMs <= Standoff.settings.graceMs then
            return true
        end
    end
    return false
end

-- Drops ladders nobody has looked at for a while (called now and then).
function Standoff.forget(now)
    for key, ladder in pairs(Standoff.ladders) do
        local keep = ladder.step >= 3 and Standoff.settings.fightMs or Standoff.settings.forgetMs
        if now - ladder.seenMs > keep then Standoff.ladders[key] = nil end
    end
end

return Standoff
