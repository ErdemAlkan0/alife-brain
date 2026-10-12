-- Trust changes how an NPC's group treats the player. A-Life decides "careful" from the
-- faction alone (Relations.playerStance): a careful group tells a player who comes close to
-- keep back and opens fire when the warnings are walked through, whatever our conversations
-- left behind. Play test (2026-10-11): after a fair trade two Riverside survivors trusted the
-- player 5-6, the next conversations still said "keep away", and the group turned on the
-- player soon after the window closed.
--
-- Now an NPC whose trust reaches settings.trust vouches for the player: while its group is
-- careful, the whole group tolerates them (Hooks.tolerate, A-Life's own careful -> neutral:
-- no warnings, and the prompt is told). The grant is renewed while the trust holds and
-- withdrawn once the best trust in the group falls below settings.keepTrust (only our own
-- grant: a longer one A-Life wrote stays). Hostile groups stay hostile (Parley talks to them).

ALifeBrain = ALifeBrain or {}

local Rapport = {
    settings = {
        trust = 5, -- one fair trade and a friendly word get there (prompt: +1/+2 talk, +3..+6 deeds)
        keepTrust = 3, -- withdrawn below this, so a trust that wobbles by 1 does not flip it
        holdMs = 600000, -- one grant (A-Life's own for a walk together: 8 minutes)
        renewMs = 300000, -- granted again once no more than this is left
        periodMs = 3000,
    },
    granted = {}, -- group key -> { untilMs = ms, uid = the NPC who vouched }
    lastMs = 0,
    stats = nil,
}
ALifeBrain.Rapport = Rapport

-- Tests replace this with fakes: { hooks = ..., minds = ..., player = ..., log = function(text) end }.
Rapport.override = nil

local function deps()
    if Rapport.override ~= nil then return Rapport.override end
    return {
        hooks = ALifeBrain.Hooks,
        minds = ALifeBrain.Dialogue ~= nil and ALifeBrain.Dialogue.minds or {},
        player = type(getSpecificPlayer) == "function" and getSpecificPlayer(0) or nil,
        log = function(text) print("[ALifeBrain] " .. text) end,
    }
end

function Rapport.reset()
    Rapport.granted, Rapport.lastMs = {}, 0
    Rapport.stats = { granted = 0, renewed = 0, withdrawn = 0 }
end
Rapport.reset()

-- Is the record's group tolerating the player because of us?
function Rapport.vouches(record, now)
    local hooks = deps().hooks
    if hooks == nil or type(record) ~= "table" then return false end
    local held = Rapport.granted[hooks.groupKey(record)]
    return held ~= nil and now < held.untilMs
end

-- The most trusting NPC we know of in each group: key -> { record, trust }.
local function bestByGroup(d)
    local best = {}
    for uid, mind in pairs(d.minds) do
        local record = d.hooks.peekRecord(uid)
        if record ~= nil and record.lifecycle ~= "dead" then
            local key, trust = d.hooks.groupKey(record), tonumber(mind.trust) or 0
            if best[key] == nil or trust > best[key].trust then best[key] = { record = record, trust = trust } end
        end
    end
    return best
end

local function grant(d, key, record, now)
    local untilMs = now + Rapport.settings.holdMs
    if not d.hooks.tolerate(record, d.player, untilMs) then return false end
    Rapport.granted[key] = { untilMs = untilMs, uid = record.uid }
    return true
end

-- Ends only our own grant: a longer one A-Life wrote since (a walk together) stays.
local function withdraw(d, key, held, record, now)
    Rapport.granted[key] = nil
    local current = d.hooks.toleratedUntil(record, d.player)
    if current == nil or current ~= held.untilMs or current <= now then return false end
    return d.hooks.tolerate(record, d.player, now)
end

-- Updates every group we know an NPC of, or only the group `only`. Returns the changes as
-- { { kind = "granted" | "withdrawn", key, record } ... }; renewals are not changes.
function Rapport.update(d, now, only)
    local changes = {}
    if d.player == nil then return changes end
    local s = Rapport.settings
    for key, entry in pairs(bestByGroup(d)) do
        if only == nil or key == only then
            local held = Rapport.granted[key]
            if held ~= nil and entry.trust < s.keepTrust then
                if withdraw(d, key, held, entry.record, now) then
                    Rapport.stats.withdrawn = Rapport.stats.withdrawn + 1
                    changes[#changes + 1] = { kind = "withdrawn", key = key, record = entry.record }
                end
            elseif held ~= nil then
                if held.untilMs - now <= s.renewMs and grant(d, key, entry.record, now) then
                    Rapport.stats.renewed = Rapport.stats.renewed + 1
                end
            elseif entry.trust >= s.trust and d.hooks.stance(entry.record, d.player) == "careful"
                    and grant(d, key, entry.record, now) then
                Rapport.stats.granted = Rapport.stats.granted + 1
                changes[#changes + 1] = { kind = "granted", key = key, record = entry.record }
            end
        end
    end
    -- A group nobody vouches for any more (dead, forgotten) keeps ours until it runs out.
    for key, held in pairs(Rapport.granted) do
        if now >= held.untilMs then Rapport.granted[key] = nil end
    end
    return changes
end

local function report(d, changes)
    for _, change in ipairs(changes) do
        local name = d.hooks.nameOf(change.record) or tostring(change.record.uid)
        pcall(d.log, "rapport: " .. name .. " (" .. change.key .. ") "
            .. (change.kind == "granted" and "trusts the player: the group lets them come close"
                or "no longer trusts the player: the group is careful again"))
    end
end

-- Called every game tick: renews grants and covers trust known from the sidecar (Moods.lua).
function Rapport.tick(now)
    if now - Rapport.lastMs < Rapport.settings.periodMs then return end
    Rapport.lastMs = now
    local d = deps()
    report(d, Rapport.update(d, now))
end

-- Right after a reply moved the NPC's trust (Dialogue.finish): its group now, before the
-- window closes and A-Life's warnings start. Returns "granted" | "withdrawn" | nil.
function Rapport.onReply(uid, now)
    local d = deps()
    local record = d.hooks.peekRecord(uid)
    if record == nil then return nil end
    local changes = Rapport.update(d, now, d.hooks.groupKey(record))
    report(d, changes)
    return changes[1] ~= nil and changes[1].kind or nil
end

return Rapport
