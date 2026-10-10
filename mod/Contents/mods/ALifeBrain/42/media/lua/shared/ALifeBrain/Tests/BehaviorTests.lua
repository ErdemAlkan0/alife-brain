require "ALifeBrain/Json"
require "ALifeBrain/Features"
require "ALifeBrain/Policy"
require "ALifeBrain/DecisionLog"
require "ALifeBrain/Companion"
require "ALifeBrain/Standoff"
require "ALifeBrain/Tests/TestRunner"

local Json, Features, Policy, DecisionLog = ALifeBrain.Json, ALifeBrain.Features, ALifeBrain.Policy, ALifeBrain.DecisionLog

local function indexOf(name)
    for index, value in ipairs(Features.NAMES) do if value == name then return index end end
end

-- Two inputs are enough to check the arithmetic; the rest of the vector is padding.
local function tinyNet()
    local mean, std = {}, {}
    for index = 1, #Features.NAMES do mean[index], std[index] = 0, 1 end
    mean[1], std[1] = 0.5, 0.5
    return {
        actions = { "default", "regroup", "flee" },
        mean = mean, std = std,
        layers = {
            { w = { { 1, 0 }, { 0, 1 } }, b = { 0, 0 }, act = "tanh" },
            { w = { { 0, 0 }, { 2, 0 }, { 0, 3 } }, b = { 0.1, 0, 0 }, act = "linear" },
        },
    }
end

ALifeBrain.Tests.suite("Features", {
    { "every feature is named and bounded", function(check)
        local vector = Features.vector({ health = 0.5, maxHealth = 1, wounds = 9, threat = true, threatKind = "player",
            threatDistance = 15, zombiesNear = 3, stance = "careful", hour = 23, order = "follow", previous = "combat",
            trust = 250, fear = -40, weaponClass = "rifle", rounds = 15 })
        check.equal(#vector, #Features.NAMES)
        for index, value in ipairs(vector) do
            check.truthy(value >= -1 and value <= 1, Features.NAMES[index] .. " out of range")
        end
        check.equal(vector[indexOf("health")], 0.5)
        check.equal(vector[indexOf("wounds")], 1, "clamped")
        check.equal(vector[indexOf("threat_player")], 1)
        check.equal(vector[indexOf("threat_zombie")], 0)
        check.equal(vector[indexOf("threat_distance")], 0.5)
        check.equal(vector[indexOf("stance_careful")], 1)
        check.equal(vector[indexOf("night")], 1)
        check.equal(vector[indexOf("order_follow")], 1)
        check.equal(vector[indexOf("was_combat")], 1)
        check.equal(vector[indexOf("trust")], 1)
        check.equal(vector[indexOf("fear")], -0.4)
        check.equal(vector[indexOf("firearm")], 1)
        check.equal(vector[indexOf("rounds")], 0.5)
    end },

    { "missing values have safe defaults", function(check)
        local vector = Features.vector(nil)
        check.equal(#vector, #Features.NAMES)
        check.equal(vector[indexOf("health")], 1, "unknown health counts as full")
        check.equal(vector[indexOf("endurance")], 1)
        check.equal(vector[indexOf("threat_distance")], 1, "no threat is far away")
        check.equal(vector[indexOf("player_distance")], 1)
        check.equal(vector[indexOf("stance_neutral")], 0)
    end },

    { "rounds for the wire", function(check)
        check.same(Features.rounded({ 0.12345, -0.98765, 1 }, 3), { 0.123, -0.988, 1 })
    end },
})

ALifeBrain.Tests.suite("Policy", {
    { "forward pass and masked choice", function(check)
        local net = tinyNet()
        local vector = {}
        for index = 1, #Features.NAMES do vector[index] = 0 end
        vector[1], vector[2] = 1, -0.5 -- standardized to 1 and -0.5
        local scores = Policy.logits(net, vector)
        local t1, t2 = (math.exp(2) - 1) / (math.exp(2) + 1), (math.exp(-1) - 1) / (math.exp(-1) + 1)
        check.truthy(math.abs(scores[1] - 0.1) < 1e-9)
        check.truthy(math.abs(scores[2] - 2 * t1) < 1e-9)
        check.truthy(math.abs(scores[3] - 3 * t2) < 1e-9)
        check.equal(Policy.choose(net, vector, { "regroup", "flee" }), "regroup")
        check.equal(Policy.choose(net, vector, { "flee" }), "default", "regroup is not allowed for this NPC")
    end },

    { "the exporter's check catches a broken forward pass", function(check)
        local net = tinyNet()
        local input = {}
        for index = 1, #Features.NAMES do input[index] = 0 end
        net.check = { input = input, logits = Policy.logits(net, input) }
        check.truthy(Policy.check(net))
        net.check.logits[2] = net.check.logits[2] + 1
        local ok, reason = Policy.check(net)
        check.equal(ok, false)
        check.equal(reason, "check_mismatch")
    end },

    { "loads only nets for this schema", function(check)
        local nets, notes = Policy.load({ schema = Features.SCHEMA, nets = { decision = tinyNet(), response = { actions = {} } } })
        check.truthy(nets.decision ~= nil)
        check.isNil(nets.response)
        check.equal(#notes, 1)
        check.isNil(Policy.load({ schema = Features.SCHEMA + 1, nets = { decision = tinyNet() } }))
        check.isNil(Policy.load(nil))
    end },
})

local Companion = ALifeBrain.Companion

-- A melee follower facing one zombie close to the player; tweak per case.
local function view(overrides)
    local base = { following = true, threatKind = "zombie", threatFromPlayer = 3, threatFromNpc = 3, npcFromPlayer = 2,
        closeZombies = 1, firearm = false, health = 1, sneaking = false, playerRunning = false }
    for key, value in pairs(overrides or {}) do base[key] = value end
    return base
end

local function companionCase(body)
    return function(check)
        local saved = Companion.fallingBack
        Companion.fallingBack = {}
        local ok, failure = pcall(body, check)
        Companion.fallingBack = saved
        if not ok then error(failure) end
    end
end

ALifeBrain.Tests.suite("Companion", {
    { "a follower fights a lone zombie near the player", companionCase(function(check)
        check.isNil(Companion.decide(view(), "a", 0), "A-Life fights it")
        check.isNil(Companion.decide(view({ following = false, closeZombies = 9 }), "a", 0), "not following: A-Life's call")
        check.isNil(Companion.decide(view({ threatKind = "player", closeZombies = 9 }), "a", 0), "people stay A-Life's")
    end) },

    { "does not chase zombies far from the player", companionCase(function(check)
        check.equal(Companion.decide(view({ threatFromPlayer = 15 }), "a", 0), "regroup")
    end) },

    { "falls back from a crowd, later for a gunner", companionCase(function(check)
        check.equal(Companion.decide(view({ closeZombies = Companion.settings.crowdMelee }), "a", 0), "fall_back")
        check.isNil(Companion.decide(view({ closeZombies = Companion.settings.crowdMelee, firearm = true }), "b", 0))
        check.equal(Companion.decide(view({ closeZombies = Companion.settings.crowdFirearm, firearm = true }), "b", 0),
            "fall_back")
    end) },

    { "falls back when badly hurt, and keeps at it for a while", companionCase(function(check)
        local hurt = view({ health = Companion.settings.woundedHealth - 0.1 })
        check.equal(Companion.decide(hurt, "a", 1000), "fall_back")
        check.equal(Companion.decide(view(), "a", 1000 + Companion.settings.fallBackMs - 1), "fall_back",
            "no flip back the moment the crowd thins")
        check.isNil(Companion.decide(view(), "a", 1000 + Companion.settings.fallBackMs))
    end) },

    { "falls back to the player only when the player is clear", companionCase(function(check)
        check.equal(Companion.fallBackTo(view({ threatFromPlayer = 12 })), "player")
        check.equal(Companion.fallBackTo(view({ threatFromPlayer = 2 })), "away", "the player is in the crowd too")
    end) },

    { "sneaking with the player leaves zombies alone unless one is on them", companionCase(function(check)
        check.equal(Companion.decide(view({ sneaking = true, threatFromPlayer = 5, threatFromNpc = 5 }), "a", 0), "regroup",
            "a zombie that has not come close is not worth the noise")
        check.isNil(Companion.decide(view({ sneaking = true, threatFromPlayer = 5, threatFromNpc = 2 }), "a", 0),
            "right on the NPC: fight")
        check.isNil(Companion.decide(view({ sneaking = true, threatFromPlayer = 1, threatFromNpc = 4 }), "a", 0),
            "right on the player: fight")
        check.equal(Companion.decide(view({ sneaking = true, closeZombies = 3 }), "b", 0), "fall_back", "crowds still")
    end) },

    { "keeps the player's pace", companionCase(function(check)
        check.equal(Companion.pace(view({ sneaking = true, threatFromNpc = 5 }), "regroup"), "walk")
        check.equal(Companion.pace(view({ sneaking = true, threatFromNpc = 1 }), "fall_back"), "run", "unless it is on them")
        check.equal(Companion.pace(view({ threatFromNpc = 5, npcFromPlayer = 3 }), "regroup"), "walk")
        check.equal(Companion.pace(view({ threatFromNpc = 5, npcFromPlayer = 12 }), "regroup"), "run", "catching up")
        check.equal(Companion.pace(view({ threatFromNpc = 5, playerRunning = true }), "regroup"), "run")
        check.equal(Companion.pace(view({ threatFromNpc = 5 }), "fall_back"), "run")
    end) },

    { "knows which followers sneak", companionCase(function(check)
        local saved = Companion.sneakers
        local sneaky, upright = { sneaks = true }, { sneaks = false }
        local found = Companion.refreshSneakers({
            a = { kind = "follow", player = sneaky }, b = { kind = "follow", player = upright },
            c = { kind = "hold", player = sneaky }, d = { kind = "follow", player = sneaky, source = "leader" },
        }, function(player) return player.sneaks end)
        check.same(found, { a = true })
        Companion.sneakers = saved
    end) },
})

local Standoff = ALifeBrain.Standoff

local function standoffCase(body)
    return function(check)
        local saved = Standoff.ladders
        Standoff.ladders = {}
        local ok, failure = pcall(body, check)
        Standoff.ladders = saved
        if not ok then error(failure) end
    end
end

ALifeBrain.Tests.suite("Standoff", {
    { "warns, warns again closer, then fights", standoffCase(function(check)
        local settings = Standoff.settings
        local step, event = Standoff.step("a>b", { distance = 20 }, 0)
        check.equal(step, "warn")
        check.equal(event, "CAREFUL_KEEP_BACK")
        check.equal(Standoff.step("a>b", { distance = 10 }, 1000), "hold", "time to react")
        step, event = Standoff.step("a>b", { distance = 10 }, settings.graceMs)
        check.equal(step, "last_warning")
        check.equal(event, "CAREFUL_LAST_WARNING")
        check.equal(Standoff.step("a>b", { distance = 10 }, settings.graceMs * 2), "hold", "kept its distance")
        step, event = Standoff.step("a>b", { distance = 5 }, settings.graceMs * 2 + 1)
        check.equal(step, "fight")
        check.equal(event, "CAREFUL_HOSTILE")
        check.equal(Standoff.step("a>b", { distance = 30 }, settings.graceMs * 3), "fight", "no new warnings mid-fight")
    end) },

    { "staying within range climbs; keeping apart ends it", standoffCase(function(check)
        local settings = Standoff.settings
        Standoff.step("a>b", { distance = 20 }, 0)
        check.equal(Standoff.step("a>b", { distance = 20 }, settings.patienceMs - 1), "hold")
        check.equal(Standoff.step("a>b", { distance = 20 }, settings.patienceMs), "last_warning")
        check.equal(Standoff.step("a>b", { distance = 20 }, settings.standMs - 1), "hold")
        local step, event, ms = Standoff.step("a>b", { distance = 20 }, settings.standMs)
        check.equal(step, "ignore", "far enough after the warnings: no fight, no staring either")
        check.isNil(event)
        check.equal(ms, settings.keepApartMs)
        check.isNil(Standoff.ladders["a>b"], "they part")
    end) },

    { "an attack skips the talking; out of range nobody bothers", standoffCase(function(check)
        check.equal(Standoff.step("a>b", { distance = 20, attacked = true }, 0), "fight")
        local step, _, ms = Standoff.step("c>d", { distance = 40 }, 0)
        check.equal(step, "ignore", "too far to warn: looked at again in a moment")
        check.equal(ms, Standoff.settings.farIgnoreMs)
        check.isNil(Standoff.ladders["c>d"], "nothing started")
    end) },

    { "forgets an NPC it has not seen for a while", standoffCase(function(check)
        local settings = Standoff.settings
        Standoff.step("a>b", { distance = 20 }, 0)
        Standoff.step("a>b", { distance = 10 }, settings.graceMs)
        check.equal(Standoff.step("a>b", { distance = 20 }, settings.graceMs + settings.forgetMs + 1), "warn",
            "starts over")
        Standoff.forget(10 * settings.fightMs)
        check.isNil(Standoff.ladders["a>b"])
    end) },
})

-- Fake bridge and hooks for DecisionLog.
local function harness(online)
    local env = { now = 10000, sent = {} }
    env.bridge = { online = online ~= false, features = { dataset = true } }
    function env.bridge:isOnline() return self.online end
    function env.bridge:send(kind, data)
        env.sent[#env.sent + 1] = { kind = kind, data = data }
        return true
    end
    env.hooks = {
        nowMs = function() return env.now end,
        decisionObservation = function() return { health = 1, threat = false } end,
        allowedModules = function() return Json.array({ "regroup", "orders" }) end,
    }
    DecisionLog.reset()
    DecisionLog.nets = nil
    DecisionLog.override = { bridge = env.bridge, hooks = env.hooks }
    return env
end

-- The live log (and a loaded policy) survive the test: ALifeBrain.runTests() may run mid-game.
local LIVE_FIELDS = { "last", "queue", "window", "lastFlushMs", "sentNames", "nets", "stats", "override" }

local function run(online, body)
    return function(check)
        local saved = {}
        for _, field in ipairs(LIVE_FIELDS) do saved[field] = DecisionLog[field] end
        local env = harness(online)
        local ok, failure = pcall(body, check, env)
        for _, field in ipairs(LIVE_FIELDS) do DecisionLog[field] = saved[field] end
        if not ok then error(failure) end
    end
end

local actor = { uid = "palife:9", factionId = "alife_church_volunteers", profileId = "volunteer" }

ALifeBrain.Tests.suite("DecisionLog", {
    { "a module the policy picked is neither training data nor compared", run(true, function(check, env)
        DecisionLog.nets = { decision = tinyNet() }
        DecisionLog.onDecision("decision", actor, {}, {}, "regroup", true)
        check.equal(#DecisionLog.queue, 0)
        check.equal(DecisionLog.stats.shadow.decision.n, 0)
        check.equal(DecisionLog.stats.chosen, 1)
        DecisionLog.onDecision("decision", actor, {}, {}, "regroup", false)
        check.equal(#DecisionLog.queue, 1, "A-Life's own choice still is")
    end) },
    { "samples a choice once per period, and every change", run(true, function(check, env)
        DecisionLog.onDecision("decision", actor, {}, {}, "regroup")
        env.now = env.now + 150
        DecisionLog.onDecision("decision", actor, {}, {}, "regroup")
        check.equal(#DecisionLog.queue, 1, "the same choice again soon is not news")
        DecisionLog.onDecision("decision", actor, {}, {}, nil)
        check.equal(#DecisionLog.queue, 2, "a different choice is")
        check.equal(DecisionLog.queue[2].a, "default", "no winner: A-Life's own fallback")
        env.now = env.now + DecisionLog.settings.samplePeriodMs
        DecisionLog.onDecision("decision", actor, {}, {}, "default")
        check.equal(#DecisionLog.queue, 3)
        DecisionLog.onDecision("response", actor, {}, {}, "flee")
        check.equal(#DecisionLog.queue, 4, "each chain on its own")
        local row = DecisionLog.queue[1]
        check.equal(#row.o, #Features.NAMES)
        check.same(row.m, { "regroup", "orders" })
        check.equal(row.f, "alife_church_volunteers")
    end) },

    { "sends batches, with the feature names first", run(true, function(check, env)
        for index = 1, DecisionLog.settings.batchRows + 2 do
            DecisionLog.onDecision("decision", { uid = "palife:" .. index }, {}, {}, "orders")
        end
        DecisionLog.tick(env.now)
        check.equal(#env.sent, 1, "a full batch goes at once")
        local first = env.sent[1].data
        check.equal(first.kind, "decision_samples")
        check.equal(first.schema, Features.SCHEMA)
        check.equal(#first.rows, DecisionLog.settings.batchRows)
        check.same(first.names, Features.NAMES)
        DecisionLog.tick(env.now + 100)
        check.equal(#env.sent, 1, "the rest waits for the flush period")
        DecisionLog.tick(env.now + DecisionLog.settings.flushMs)
        check.equal(#env.sent, 2)
        check.isNil(env.sent[2].data.names, "names only once")
        check.equal(DecisionLog.stats.sent, DecisionLog.settings.batchRows + 2)
        local line = Json.encode({ v = 1, type = "event", data = first })
        check.truthy(#line < 16000, "fits the bridge line limit (" .. tostring(#line) .. ")")
    end) },

    { "nothing is collected without a sidecar that stores it", run(false, function(check, env)
        DecisionLog.onDecision("decision", actor, {}, {}, "regroup")
        check.equal(#DecisionLog.queue, 0)
        env.bridge.online = true
        env.bridge.features = { dialogue = true }
        DecisionLog.onDecision("decision", actor, {}, {}, "regroup")
        check.equal(#DecisionLog.queue, 0, "an older sidecar without the dataset feature")
    end) },

    { "caps the samples per second", run(true, function(check, env)
        for index = 1, DecisionLog.settings.maxPerSecond + 5 do
            DecisionLog.onDecision("decision", { uid = "palife:" .. index }, {}, {}, "orders")
        end
        check.equal(#DecisionLog.queue, DecisionLog.settings.maxPerSecond)
        check.equal(DecisionLog.stats.dropped, 5)
    end) },

    { "shadow mode counts agreement without collecting", run(false, function(check, env)
        DecisionLog.nets = { decision = tinyNet() }
        env.hooks.decisionObservation = function() return { health = 1 } end -- standardized health 1 -> regroup wins
        DecisionLog.onDecision("decision", actor, {}, {}, "regroup")
        DecisionLog.onDecision("decision", { uid = "palife:10" }, {}, {}, "orders")
        local agreement = DecisionLog.agreement().decision
        check.equal(agreement.n, 2)
        check.equal(agreement.agree, 1)
        check.equal(#DecisionLog.queue, 0, "offline: only counted")
    end) },
})
