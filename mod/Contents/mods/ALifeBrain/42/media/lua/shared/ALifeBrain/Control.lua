-- Phase 5: the trained policy (PolicyWeights.lua) chooses among A-Life's own modules,
-- steered by what conversations left in Dialogue.minds (trust, fear, drive). The decision
-- tap (Hooks.installDecisionTap) asks Control.pick before A-Life runs a chain: the named
-- module runs alone; when it has nothing to do, or nothing is named, A-Life's chain runs as
-- before. The policy only ever adds a choice, it never stops one of A-Life's:
--   * never named: A-Life's own fallback ("default"), talk, robbery, orders, and our
--     follower and parley modules (the player's words and orders drive those);
--   * left to A-Life: a player's order to this NPC (follow / stay), a conversation (talk
--     hold, a reply on its way), a robbery under way, a parley or NPC standoff it is part
--     of, a player as the threat, and an NPC hostile to a player within hostileTiles (A-Life's
--     robbery module spots players 55 tiles away);
--   * near a player (socialTiles) only a warning ("careful") may be added, so A-Life's
--     greetings (6 tiles) and warnings (14) keep their turn.
-- Off by default: the Mod Options tick box (Control.option) or ALifeBrain.control(true).

require "ALifeBrain/Features"
require "ALifeBrain/Policy"

ALifeBrain = ALifeBrain or {}

local Features, Policy = ALifeBrain.Features, ALifeBrain.Policy

local Control = {
    settings = {
        periodMs = 2500, -- the policy is asked again per NPC and chain at most this often
        socialTiles = 20, -- A-Life's careful module warns players 14 tiles away (some encounters more)
        hostileTiles = 55, -- ModuleRobbery.detectRadius
        forgetMs = 600000,
    },
    NEVER = { default = true, talk = true, robbery = true, orders = true, alifeBrainCompanion = true,
        alifeBrainParley = true },
    NEAR_PLAYER = { careful = true },
    forced = nil, -- true / false from the debug console; nil follows the option
    option = nil, -- PZAPI.ModOptions tick box (client), read on every decision
    cache = nil,
    stats = nil,
}
ALifeBrain.Control = Control

-- Tests replace this with fakes: { hooks, dialogue, nets, parley, standoff, moods }.
Control.override = nil

local function deps()
    if Control.override ~= nil then return Control.override end
    local log = ALifeBrain.DecisionLog
    return { hooks = ALifeBrain.Hooks, dialogue = ALifeBrain.Dialogue, nets = log ~= nil and log.nets or nil,
        parley = ALifeBrain.Parley, standoff = ALifeBrain.Standoff, moods = ALifeBrain.Moods }
end

local function chainStats() return { asked = 0, picked = 0, ran = 0, declined = 0, left = 0, near = 0 } end

function Control.reset()
    Control.cache = { decision = {}, response = {} }
    Control.stats = { decision = chainStats(), response = chainStats(), modules = {}, reasons = {} }
end
Control.reset()

function Control.enabled()
    if Control.forced ~= nil then return Control.forced == true end
    local option = Control.option
    if option == nil or type(option.getValue) ~= "function" then return false end
    local ok, value = pcall(option.getValue, option)
    return ok and value == true
end

-- Why A-Life keeps this decision, or nil when the policy may choose; also the distance to
-- the nearest player for decisions (nil: none).
function Control.leaveToALife(kind, actor, shell, context, now, d)
    local uid = actor.uid
    local memory = type(actor.memory) == "table" and actor.memory or {}
    if d.hooks.orderOf(uid) ~= nil then return "order" end
    if (tonumber(memory.talkHoldUntilMs) or 0) > now then return "talk" end
    if d.dialogue ~= nil and d.dialogue.pending[uid] ~= nil then return "talk" end
    if memory.robbery ~= nil then return "robbery" end
    if d.parley ~= nil and d.parley.involves(uid) then return "parley" end
    if kind == "response" then
        if type(context) == "table" and context.threatKind == "player" then return "player_threat" end
        if d.standoff ~= nil and d.standoff.involves(uid, now) then return "standoff" end
        return nil
    end
    local player, distance = d.hooks.nearestPlayer(shell)
    if distance ~= nil and distance <= Control.settings.hostileTiles and d.hooks.stance(actor, player) == "hostile" then
        return "hostile_player"
    end
    return nil, distance
end

-- Hooks.decisionChooser: the module to run alone, or nil for A-Life's chain.
function Control.pick(kind, actor, shell, context)
    if not Control.enabled() then return nil end
    local stats = Control.stats[kind]
    if stats == nil or type(actor) ~= "table" or type(actor.uid) ~= "string" then return nil end
    local d = deps()
    local net = d.nets ~= nil and d.nets[kind] or nil
    if net == nil then return nil end
    local now = d.hooks.nowMs()
    local uid = actor.uid
    if d.moods ~= nil then d.moods.want(uid, now) end
    local reason, distance = Control.leaveToALife(kind, actor, shell, context, now, d)
    if reason ~= nil then
        stats.left = stats.left + 1
        Control.stats.reasons[reason] = (Control.stats.reasons[reason] or 0) + 1
        return nil
    end
    local byUid = Control.cache[kind]
    local entry = byUid[uid]
    if entry == nil or now >= entry.untilMs then
        local raw = d.hooks.decisionObservation(kind, actor, shell, context, now)
        local choice = Policy.choose(net, Features.vector(raw), d.hooks.allowedModules(kind, actor))
        entry = { choice = choice, untilMs = now + Control.settings.periodMs, declined = false }
        byUid[uid] = entry
        stats.asked = stats.asked + 1
    end
    local choice = entry.choice
    if entry.declined or Control.NEVER[choice] then return nil end
    if kind == "decision" and not Control.NEAR_PLAYER[choice] and distance ~= nil
            and distance <= Control.settings.socialTiles then
        stats.near = stats.near + 1
        return nil
    end
    stats.picked = stats.picked + 1
    return choice
end

-- Hooks.decisionChosen: ran is false when the module had nothing to do (A-Life's chain then
-- decided); that pick is not tried again until the policy is asked again.
function Control.onChosen(kind, actor, choice, ran)
    local stats = Control.stats[kind]
    if stats == nil then return end
    if ran then
        stats.ran = stats.ran + 1
        local key = kind .. ":" .. tostring(choice)
        Control.stats.modules[key] = (Control.stats.modules[key] or 0) + 1
        return
    end
    stats.declined = stats.declined + 1
    local entry = type(actor) == "table" and Control.cache[kind][actor.uid] or nil
    if entry ~= nil and entry.choice == choice then entry.declined = true end
end

-- Drops cached picks of NPCs not seen for a while (called now and then).
function Control.forget(now)
    for _, byUid in pairs(Control.cache) do
        for uid, entry in pairs(byUid) do
            if now - entry.untilMs > Control.settings.forgetMs then byUid[uid] = nil end
        end
    end
end

return Control
