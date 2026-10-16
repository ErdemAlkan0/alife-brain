-- Parley: a hostile NPC that sees the player talks before it shoots (user request,
-- 2026-10-09: "demand tribute or threaten; fight if the window closes or the talk fails").
--
-- The Hooks "response" module calls Parley.consider when A-Life is about to fight the player.
-- The crew gets A-Life's own robbery truce (Relations.hostileToPlayer is false while it
-- lasts), renewed every couple of seconds while the talk goes on; the NPC that called out
-- stands and faces the player, and the conversation window opens with its opening line
-- (the LLM plays a hostile crew in a standoff). It ends:
--   * in a fight: the player closes the window, attacks one of the crew, stalls too long,
--     or the NPC's reply is intent "attack" -> the truce ends and the crew turns on the player
--   * in peace: the player pays (a trade the NPC gets something from) or the NPC sends them
--     off (intent "leave") -> the truce stays for a while so they can go
--   * when the player gets far away, or the NPC is gone -> the truce just ends
-- One parley at a time; the same crew does not parley with the same player again soon.
-- Without the sidecar's dialogue feature nothing changes: A-Life fights as before.

ALifeBrain = ALifeBrain or {}

local Parley = {
    MODULE_ID = "alifeBrainParley",
    settings = {
        -- A-Life sees the player from about 30 tiles (up to ~50 when they run in daylight) and its
        -- riflemen open fire from there; at 25 tiles no parley ever started (play test, 2026-10-09).
        noticeTiles = 60, -- a hostile NPC this close that sees the player calls out instead of shooting
        reachTiles = 75, -- the player farther than this: they got away, the parley is over
        crewTiles = 40, -- squad mates this close hold their fire too
        holdMs = 6000, -- each truce renewal lasts this long
        renewMs = 2000,
        patienceMs = 45000, -- no word from the player for this long (the NPC not thinking): it shoots
        leaveTruceMs = 180000, -- sent away: this long to get going
        tributeTruceMs = 900000, -- paid: left alone this long
        cooldownMs = 600000, -- the same crew and player parley at most once in this long
        -- A-Life may notice the player before there is a clear line between them (a fence, a
        -- corner): the NPC waits this long for sight instead of opening fire unseen (play test,
        -- 2026-10-12: 3 of 26 crews).
        sightWaitMs = 8000,
        attackedMs = 120000, -- a crew the player hit no longer than this ago shoots
    },
    unseenSince = {}, -- uid -> since when it has waited to see the player
    attackedAtMs = {}, -- group key -> when the player last hit one of them
    active = nil,
    cooldowns = {},
    stats = { started = 0, paid = 0, sentAway = 0, fights = 0, gotAway = 0 },
    -- Set by the conversation window: onOpen(parley) opens it, onEnd(parley, outcome, reason)
    -- shows how it ended. outcome: "fight" | "paid" | "sent_away" | "got_away" | "gone".
    onOpen = nil,
    onEnd = nil,
    lastNote = nil,
    noted = {}, -- uid -> the last reason logged for not parleying (each change is logged once)
}
ALifeBrain.Parley = Parley

-- Tests replace this with fakes: { hooks = ..., dialogueReady = function() ... end, thinking = function(uid) ... end }.
Parley.override = nil

local function deps()
    if Parley.override ~= nil then return Parley.override end
    local Dialogue = ALifeBrain.Dialogue
    return {
        hooks = ALifeBrain.Hooks,
        dialogueReady = function() return Dialogue ~= nil and Dialogue.supported() end,
        thinking = function(uid) return Dialogue ~= nil and Dialogue.pending[uid] ~= nil end,
        log = function(message) print("[ALifeBrain] " .. message) end,
    }
end

local function note(d, message)
    if type(d.log) == "function" then pcall(d.log, message) end
end

local function cooldownKey(groupKey, playerKey) return tostring(groupKey) .. "|" .. tostring(playerKey) end

function Parley.isActive(uid)
    return Parley.active ~= nil and (uid == nil or Parley.active.uid == uid)
end

-- True while this NPC calls out or holds its fire with its crew.
function Parley.involves(uid)
    local active = Parley.active
    if active == nil then return false end
    return active.uid == uid or (type(active.crew) == "table" and active.crew[uid] ~= nil and active.crew[uid] ~= false)
end

-- "hold" when this NPC should hold its fire (it calls out, or its crew is talking), nil to
-- leave the fight to A-Life.
function Parley.consider(actor, shell, player, now)
    local active = Parley.active
    if active ~= nil then
        if active.crew[actor.uid] then return "hold" end
        return nil -- one parley at a time
    end
    local d = deps()
    if not d.dialogueReady() then return nil end
    local groupKey = d.hooks.groupKey(actor)
    local playerKey = d.hooks.reputationKey(player)
    if (Parley.cooldowns[cooldownKey(groupKey, playerKey)] or 0) > now then return nil end
    local blocked, feud = d.hooks.parleyBlocked(actor, shell, player, now, Parley.settings.noticeTiles)
    if (Parley.attackedAtMs[groupKey] or -math.huge) > now - Parley.settings.attackedMs then blocked = "attacked" end
    if blocked == "unseen" then
        local since = Parley.unseenSince[actor.uid]
        if since == nil then since, Parley.unseenSince[actor.uid] = now, now end
        if now - since < Parley.settings.sightWaitMs then return "hold" end
    else
        Parley.unseenSince[actor.uid] = nil
    end
    if blocked ~= nil then
        Parley.lastNote = blocked
        if Parley.noted[actor.uid] ~= blocked then
            Parley.noted[actor.uid] = blocked
            note(d, "parley: " .. tostring(actor.uid) .. " shoots instead (" .. tostring(blocked) .. ")")
        end
        return nil
    end
    Parley.start(actor, shell, player, now, groupKey, playerKey, feud)
    return "hold"
end

-- feud: the crew's faction counts the player as an enemy (Hooks.parleyBlocked); the LLM is told.
function Parley.start(actor, shell, player, now, groupKey, playerKey, feud)
    local d = deps()
    local parley = { uid = actor.uid, shell = shell, player = player, playerKey = playerKey, groupKey = groupKey,
        crew = d.hooks.crewOf(actor, shell, Parley.settings.crewTiles), startedMs = now, heardMs = now, renewedMs = 0,
        feud = feud == true }
    Parley.active = parley
    Parley.stats.started = Parley.stats.started + 1
    local size = 0
    for _ in pairs(parley.crew) do size = size + 1 end
    note(d, "parley: " .. tostring(actor.uid) .. " calls out (crew of " .. tostring(size) .. ")"
        .. (parley.feud and "; its faction holds a grudge" or ""))
    Parley.renew(now)
    d.hooks.voice(shell, "CAREFUL_KEEP_BACK")
    if type(Parley.onOpen) == "function" then pcall(Parley.onOpen, parley) end
    return parley
end

function Parley.renew(now)
    local parley = Parley.active
    if parley == nil then return end
    parley.renewedMs = now
    deps().hooks.truce(parley.crew, parley.player, now + Parley.settings.holdMs)
end

local function close(outcome, reason, truceUntilMs, now)
    local parley = Parley.active
    if parley == nil then return nil end
    Parley.active = nil
    local d = deps()
    d.hooks.truce(parley.crew, parley.player, truceUntilMs)
    Parley.cooldowns[cooldownKey(parley.groupKey, parley.playerKey)] = now + Parley.settings.cooldownMs
    parley.outcome, parley.reason = outcome, reason
    note(d, "parley: " .. tostring(parley.uid) .. " ended: " .. tostring(outcome) .. " (" .. tostring(reason) .. ")")
    if type(Parley.onEnd) == "function" then pcall(Parley.onEnd, parley, outcome, reason) end
    return parley
end

-- The talk failed: the crew stops holding its fire.
function Parley.fight(reason, now)
    local parley = Parley.active
    if parley == nil then return nil end
    local d = deps()
    d.hooks.voice(parley.shell, "CAREFUL_HOSTILE")
    Parley.stats.fights = Parley.stats.fights + 1
    close("fight", reason, nil, now)
    d.hooks.rethink(parley.crew)
    return parley
end

-- The talk worked: they let the player go for a while.
function Parley.peace(outcome, now)
    if Parley.active == nil then return nil end
    local paid = outcome == "paid"
    if paid then Parley.stats.paid = Parley.stats.paid + 1 else Parley.stats.sentAway = Parley.stats.sentAway + 1 end
    local truce = paid and Parley.settings.tributeTruceMs or Parley.settings.leaveTruceMs
    return close(outcome, outcome, now + truce, now)
end

-- Called every game tick.
function Parley.tick(now)
    local parley = Parley.active
    if parley == nil then return end
    local d = deps()
    local hooks = d.hooks
    local record = hooks.readRecord(parley.uid)
    local playerDead = true
    pcall(function() playerDead = parley.player:isDead() end)
    if record == nil or not hooks.talkable(parley.shell, record) or playerDead then
        close("gone", "gone", nil, now)
        return
    end
    if not hooks.withinReach(parley.player, parley.shell, Parley.settings.reachTiles) then
        Parley.stats.gotAway = Parley.stats.gotAway + 1
        close("got_away", "got_away", nil, now)
        return
    end
    if d.thinking(parley.uid) then
        parley.heardMs = now -- the NPC is answering; the player is not stalling
    elseif now - parley.heardMs > Parley.settings.patienceMs then
        Parley.fight("patience", now)
        return
    end
    if now - parley.renewedMs >= Parley.settings.renewMs then Parley.renew(now) end
end

-- The player said something in the window.
function Parley.onPlayerLine(uid, now)
    if Parley.isActive(uid) then Parley.active.heardMs = now end
end

-- The NPC answered (Dialogue.finish): reply.intent attack ends it in a fight, leave in peace.
function Parley.onReply(uid, reply, now)
    if not Parley.isActive(uid) then return nil end
    Parley.active.heardMs = now
    local intent = type(reply) == "table" and reply.intent or nil
    if intent == "attack" then return Parley.fight("refused", now) end
    if intent == "leave" then return Parley.peace("sent_away", now) end
    return nil
end

-- A trade went through (Dialogue.executeTrade): the NPC got something, so the player paid.
function Parley.onTrade(uid, outcome, now)
    if not Parley.isActive(uid) or type(outcome) ~= "table" or outcome.ok ~= true then return nil end
    if type(outcome.received) == "table" and #outcome.received > 0 then return Parley.peace("paid", now) end
    return nil
end

-- The conversation window closed before the talk ended.
function Parley.onWindowClosed(uid, now)
    if Parley.isActive(uid) then return Parley.fight("walked_off", now) end
    return nil
end

-- The player hit an NPC (EventLog): one of the crew means the talking is over, and that NPC's
-- group shoots rather than talks for a while (A-Life does not mark an already hostile crew).
function Parley.onPlayerAttack(uid, now)
    local record = deps().hooks.readRecord(uid)
    Parley.attackedAtMs[record ~= nil and deps().hooks.groupKey(record) or ("solo:" .. tostring(uid))] = now
    Parley.unseenSince[uid] = nil
    if Parley.active ~= nil and Parley.active.crew[uid] then return Parley.fight("attacked", now) end
    return nil
end

-- Drops what it remembers about attacks and waiting (called now and then).
function Parley.forget(now)
    for key, at in pairs(Parley.attackedAtMs) do
        if now - at > Parley.settings.attackedMs then Parley.attackedAtMs[key] = nil end
    end
    for uid, since in pairs(Parley.unseenSince) do
        if now - since > Parley.settings.sightWaitMs * 4 then Parley.unseenSince[uid] = nil end
    end
end

return Parley
