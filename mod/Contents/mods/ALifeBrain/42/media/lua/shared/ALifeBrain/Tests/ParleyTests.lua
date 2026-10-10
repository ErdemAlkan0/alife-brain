require "ALifeBrain/Parley"
require "ALifeBrain/Tests/TestRunner"

local Parley = ALifeBrain.Parley

-- Fake A-Life side: records truces, voices and re-thinks; tweak env fields per case.
local function harness()
    local env = { now = 1000, truces = {}, voices = {}, rethinks = 0, opened = {}, ended = {}, blocked = nil,
        ready = true, thinking = false, reach = true, talkable = true, records = { leader = { uid = "leader" } } }
    env.player = { dead = false }
    function env.player:isDead() return self.dead end
    env.hooks = {
        groupKey = function(actor) return actor.group or ("solo:" .. actor.uid) end,
        reputationKey = function() return "sp:0" end,
        parleyBlocked = function() return env.blocked end,
        crewOf = function(actor) return { [actor.uid] = true, mate = true } end,
        truce = function(crew, player, untilMs) env.truces[#env.truces + 1] = { crew = crew, untilMs = untilMs } end,
        voice = function(_, event) env.voices[#env.voices + 1] = event end,
        rethink = function() env.rethinks = env.rethinks + 1 end,
        readRecord = function(uid) return env.records[uid] end,
        talkable = function() return env.talkable end,
        withinReach = function() return env.reach end,
    }
    env.deps = { hooks = env.hooks, dialogueReady = function() return env.ready end,
        thinking = function() return env.thinking end }
    return env
end

local LIVE = { "active", "cooldowns", "stats", "onOpen", "onEnd", "override", "lastNote", "noted" }

local function run(body)
    return function(check)
        local saved = {}
        for _, field in ipairs(LIVE) do saved[field] = Parley[field] end
        local env = harness()
        Parley.active, Parley.cooldowns, Parley.override, Parley.noted = nil, {}, env.deps, {}
        Parley.stats = { started = 0, paid = 0, sentAway = 0, fights = 0, gotAway = 0 }
        Parley.onOpen = function(parley) env.opened[#env.opened + 1] = parley end
        Parley.onEnd = function(parley, outcome, reason) env.ended[#env.ended + 1] = { outcome = outcome, reason = reason } end
        local ok, failure = pcall(body, check, env)
        for _, field in ipairs(LIVE) do Parley[field] = saved[field] end
        if not ok then error(failure) end
    end
end

local leader = { uid = "leader", group = "g1" }
local mate = { uid = "mate", group = "g1" }
local stranger = { uid = "other", group = "g2" }

ALifeBrain.Tests.suite("Parley", {
    { "a hostile NPC calls out instead of shooting, and its crew holds fire", run(function(check, env)
        check.equal(Parley.consider(leader, {}, env.player, env.now), "hold")
        check.equal(#env.opened, 1, "the window opens")
        check.equal(env.voices[1], "CAREFUL_KEEP_BACK")
        local truce = env.truces[1]
        check.truthy(truce.crew.leader and truce.crew.mate)
        check.equal(truce.untilMs, env.now + Parley.settings.holdMs)
        check.equal(Parley.consider(mate, {}, env.player, env.now), "hold", "squad mates hold their fire too")
        check.isNil(Parley.consider(stranger, {}, env.player, env.now), "one parley at a time; others are A-Life's")
    end) },

    { "without the LLM, or when it would rather shoot, A-Life fights", run(function(check, env)
        env.ready = false
        check.isNil(Parley.consider(leader, {}, env.player, env.now))
        env.ready, env.blocked = true, "grudge"
        check.isNil(Parley.consider(leader, {}, env.player, env.now))
        check.equal(Parley.lastNote, "grudge")
        check.isNil(Parley.active)
    end) },

    { "the truce is renewed while they talk; stalling ends in a fight", run(function(check, env)
        Parley.consider(leader, {}, env.player, env.now)
        Parley.tick(env.now + Parley.settings.renewMs)
        check.equal(#env.truces, 2, "renewed")
        env.thinking = true
        Parley.tick(env.now + Parley.settings.patienceMs * 2)
        check.truthy(Parley.active ~= nil, "the NPC was thinking: nobody is stalling")
        env.thinking = false
        Parley.tick(env.now + Parley.settings.patienceMs * 3 + 1)
        check.isNil(Parley.active)
        check.equal(env.ended[1].outcome, "fight")
        check.equal(env.ended[1].reason, "patience")
        check.isNil(env.truces[#env.truces].untilMs, "the truce is over")
        check.equal(env.voices[#env.voices], "CAREFUL_HOSTILE")
        check.equal(env.rethinks, 1, "the crew turns on the player now")
        check.isNil(Parley.consider(leader, {}, env.player, env.now + 1000), "not the same crew again so soon")
    end) },

    { "attack in the reply, a closed window or a hit start the fight", run(function(check, env)
        Parley.consider(leader, {}, env.player, env.now)
        Parley.onReply("leader", { intent = "warn" }, env.now + 1)
        check.truthy(Parley.active ~= nil, "talk goes on")
        Parley.onReply("leader", { intent = "attack" }, env.now + 2)
        check.equal(env.ended[1].reason, "refused")
        Parley.cooldowns = {}
        Parley.consider(leader, {}, env.player, env.now)
        Parley.onWindowClosed("leader", env.now + 3)
        check.equal(env.ended[2].reason, "walked_off")
        Parley.cooldowns = {}
        Parley.consider(leader, {}, env.player, env.now)
        Parley.onPlayerAttack("someone else", env.now)
        check.truthy(Parley.active ~= nil, "not one of the crew")
        Parley.onPlayerAttack("mate", env.now + 4)
        check.equal(env.ended[3].reason, "attacked")
    end) },

    { "paying or being sent off ends in peace, with a truce to get away", run(function(check, env)
        Parley.consider(leader, {}, env.player, env.now)
        check.isNil(Parley.onTrade("leader", { ok = true, received = {} }, env.now), "nothing handed over")
        Parley.onTrade("leader", { ok = true, received = { "Beans" } }, env.now + 10)
        check.equal(env.ended[1].outcome, "paid")
        check.equal(env.truces[#env.truces].untilMs, env.now + 10 + Parley.settings.tributeTruceMs)
        Parley.cooldowns = {}
        Parley.consider(leader, {}, env.player, env.now)
        Parley.onReply("leader", { intent = "leave" }, env.now + 20)
        check.equal(env.ended[2].outcome, "sent_away")
        check.equal(env.truces[#env.truces].untilMs, env.now + 20 + Parley.settings.leaveTruceMs)
        check.equal(Parley.stats.paid, 1)
        check.equal(Parley.stats.sentAway, 1)
        Parley.onWindowClosed("leader", env.now + 30)
        check.equal(#env.ended, 2, "closing the window after peace is not a fight")
    end) },

    { "getting away, or the NPC gone, just ends it", run(function(check, env)
        Parley.consider(leader, {}, env.player, env.now)
        env.reach = false
        Parley.tick(env.now + 1)
        check.equal(env.ended[1].outcome, "got_away")
        check.isNil(env.truces[#env.truces].untilMs)
        Parley.cooldowns = {}
        env.reach = true
        Parley.consider(leader, {}, env.player, env.now)
        env.records.leader = nil
        Parley.tick(env.now + 2)
        check.equal(env.ended[2].outcome, "gone")
        check.equal(env.rethinks, 0, "no fight")
    end) },
})
