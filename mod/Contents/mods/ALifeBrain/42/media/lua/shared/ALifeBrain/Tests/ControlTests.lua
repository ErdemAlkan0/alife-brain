require "ALifeBrain/Json"
require "ALifeBrain/Dialogue"
require "ALifeBrain/Moods"
require "ALifeBrain/Control"
require "ALifeBrain/ALifeBrainHooks"
require "ALifeBrain/Tests/TestRunner"

local Json, Dialogue, Moods, Control, Hooks = ALifeBrain.Json, ALifeBrain.Dialogue, ALifeBrain.Moods,
    ALifeBrain.Control, ALifeBrain.Hooks

-- A net whose scores follow the list: the first action wins wherever it is allowed.
local function preferring(order)
    local actions, rows, biases = {}, {}, {}
    for index, name in ipairs(order) do
        actions[index], rows[index], biases[index] = name, {}, #order - index
    end
    return { actions = actions, mean = {}, std = {}, layers = { { w = rows, b = biases, act = "linear" } } }
end

local function controlEnv()
    local env = { now = 50000, observed = 0 }
    env.hooks = {
        nowMs = function() return env.now end,
        orderOf = function() return env.order end,
        nearestPlayer = function()
            if env.distance == nil then return nil end
            return { name = "player" }, env.distance
        end,
        stance = function() return env.stance or "neutral" end,
        decisionObservation = function()
            env.observed = env.observed + 1
            return { health = 1 }
        end,
        allowedModules = function() return { "scavenge", "careful", "orders", "flee" } end,
    }
    env.dialogue = { pending = {} }
    env.parley = { involves = function() return env.parley_on == true end }
    env.standoff = { involves = function() return env.standoff_on == true end }
    env.moods = { want = function(uid) env.wanted = uid end }
    env.nets = { decision = preferring({ "scavenge", "careful", "default" }), response = preferring({ "flee", "default" }) }
    return env
end

-- The live Control (and its switch) survive the test: ALifeBrain.runTests() may run mid-game.
local function withControl(body)
    return function(check)
        local saved = { forced = Control.forced, override = Control.override, cache = Control.cache, stats = Control.stats }
        local env = controlEnv()
        Control.reset()
        Control.forced = true
        Control.override = env
        local ok, failure = pcall(body, check, env)
        for key, value in pairs(saved) do Control[key] = value end
        if not ok then error(failure) end
    end
end

local npc = { uid = "test:control:1", memory = {} }

ALifeBrain.Tests.suite("Control", {
    { "stays out of the way while off", withControl(function(check, env)
        Control.forced = false
        check.isNil(Control.pick("decision", npc, {}, {}))
        check.equal(env.observed, 0)
    end) },
    { "names the policy's module and asks it again only after a while", withControl(function(check, env)
        check.equal(Control.pick("decision", npc, {}, {}), "scavenge")
        check.equal(env.wanted, npc.uid, "its stored mood is fetched for the next time")
        env.now = env.now + 100
        check.equal(Control.pick("decision", npc, {}, {}), "scavenge")
        check.equal(env.observed, 1, "cached")
        env.now = env.now + Control.settings.periodMs
        Control.pick("decision", npc, {}, {})
        check.equal(env.observed, 2)
        check.equal(Control.pick("response", npc, {}, { threatKind = "zombie" }), "flee", "each chain its own net")
    end) },
    { "never names A-Life's fallback or the modules the player drives", withControl(function(check, env)
        env.nets.decision = preferring({ "orders", "default" })
        check.isNil(Control.pick("decision", npc, {}, {}))
        env.nets.decision = preferring({ "default", "scavenge" })
        env.now = env.now + Control.settings.periodMs
        check.isNil(Control.pick("decision", npc, {}, {}))
    end) },
    { "leaves orders, conversations, robberies, parleys and player threats to A-Life", withControl(function(check, env)
        env.order = { kind = "follow" }
        check.isNil(Control.pick("decision", npc, {}, {}))
        env.order = nil
        local talking = { uid = "test:control:2", memory = { talkHoldUntilMs = env.now + 5000 } }
        check.isNil(Control.pick("decision", talking, {}, {}))
        local robbing = { uid = "test:control:3", memory = { robbery = { player = "sp:0" } } }
        check.isNil(Control.pick("decision", robbing, {}, {}))
        env.parley_on = true
        check.isNil(Control.pick("decision", npc, {}, {}))
        env.parley_on = false
        check.isNil(Control.pick("response", npc, {}, { threatKind = "player" }))
        env.standoff_on = true
        check.isNil(Control.pick("response", npc, {}, { threatKind = "actor" }))
        local reasons = Control.stats.reasons
        check.same({ reasons.order, reasons.talk, reasons.robbery, reasons.parley, reasons.player_threat, reasons.standoff },
            { 1, 1, 1, 1, 1, 1 })
        check.equal(env.observed, 0, "the policy was not even asked")
        env.dialogue.pending[npc.uid] = { id = "x" }
        env.standoff_on = false
        check.isNil(Control.pick("decision", npc, {}, {}), "a reply on its way")
    end) },
    { "an NPC hostile to a player in robbery range is A-Life's", withControl(function(check, env)
        env.stance, env.distance = "hostile", 50
        check.isNil(Control.pick("decision", npc, {}, {}))
        check.equal(Control.stats.reasons.hostile_player, 1)
        check.equal(env.observed, 0)
        env.distance = 70
        check.equal(Control.pick("decision", npc, {}, {}), "scavenge", "far enough")
        env.stance, env.distance = "neutral", 50
        env.now = env.now + Control.settings.periodMs
        check.equal(Control.pick("decision", npc, {}, {}), "scavenge")
        env.stance, env.distance = "hostile", 5
        check.equal(Control.pick("response", npc, {}, { threatKind = "zombie" }), "flee", "a zombie is still its call")
    end) },
    { "near a player it may only add a warning", withControl(function(check, env)
        env.distance = 12
        check.isNil(Control.pick("decision", npc, {}, {}))
        check.equal(Control.stats.decision.near, 1)
        env.nets.decision = preferring({ "careful", "scavenge" })
        env.now = env.now + Control.settings.periodMs
        check.equal(Control.pick("decision", npc, {}, {}), "careful")
        env.distance = 40
        env.nets.decision = preferring({ "scavenge" })
        env.now = env.now + Control.settings.periodMs
        check.equal(Control.pick("decision", npc, {}, {}), "scavenge")
        env.distance = 5
        check.equal(Control.pick("response", npc, {}, { threatKind = "zombie" }), "flee", "threat answers are its own")
    end) },
    { "a module with nothing to do waits until the policy is asked again", withControl(function(check, env)
        check.equal(Control.pick("decision", npc, {}, {}), "scavenge")
        Control.onChosen("decision", npc, "scavenge", false)
        check.isNil(Control.pick("decision", npc, {}, {}))
        env.now = env.now + Control.settings.periodMs
        check.equal(Control.pick("decision", npc, {}, {}), "scavenge")
        Control.onChosen("decision", npc, "scavenge", true)
        check.equal(Control.stats.modules["decision:scavenge"], 1)
        check.equal(Control.stats.decision.declined, 1)
    end) },
    { "without trained weights A-Life decides", withControl(function(check, env)
        env.nets = nil
        check.isNil(Control.pick("decision", npc, {}, {}))
    end) },
})

-- Hooks.wrapEvaluate on a fake Registry.evaluate.
local function withTap(body)
    return function(check)
        local saved = { tap = Hooks.decisionTap, chooser = Hooks.decisionChooser, chosen = Hooks.decisionChosen,
            chooserError = Hooks.decisionChooserError }
        local env = { calls = {}, taps = {}, chosen = {}, answers = {} }
        local function original(kind, actor, shell, context, only)
            env.calls[#env.calls + 1] = only or "chain"
            local answer = env.answers[only or "chain"]
            if answer == nil then return nil end
            return { kind = "idle", intent = answer }, answer
        end
        Hooks.decisionTap = function(kind, actor, shell, context, moduleId, chosen)
            env.taps[#env.taps + 1] = { moduleId = moduleId, chosen = chosen }
        end
        Hooks.decisionChooser = function() return env.pick end
        Hooks.decisionChosen = function(kind, actor, choice, ran) env.chosen[#env.chosen + 1] = { choice, ran } end
        local ok, failure = pcall(body, check, env, Hooks.wrapEvaluate(original))
        Hooks.decisionTap, Hooks.decisionChooser, Hooks.decisionChosen = saved.tap, saved.chooser, saved.chosen
        Hooks.decisionChooserError = saved.chooserError
        if not ok then error(failure) end
    end
end

ALifeBrain.Tests.suite("Decision tap", {
    { "runs the pick alone and reports it as the policy's", withTap(function(check, env, evaluate)
        env.pick, env.answers = "scavenge", { scavenge = "scavenge", chain = "patrolRest" }
        local state, moduleId = evaluate("decision", npc, {}, {})
        check.equal(moduleId, "scavenge")
        check.equal(state.intent, "scavenge")
        check.same(env.calls, { "scavenge" }, "A-Life's chain never ran")
        check.same(env.taps, { { moduleId = "scavenge", chosen = true } })
        check.same(env.chosen, { { "scavenge", true } })
    end) },
    { "a pick with nothing to do falls back to the whole chain", withTap(function(check, env, evaluate)
        env.pick, env.answers = "scavenge", { chain = "patrolRest" }
        local _, moduleId = evaluate("decision", npc, {}, {})
        check.equal(moduleId, "patrolRest")
        check.same(env.calls, { "scavenge", "chain" })
        check.same(env.taps, { { moduleId = "patrolRest", chosen = false } })
        check.same(env.chosen, { { "scavenge", false } })
    end) },
    { "no pick, lull calls and other dispatches go straight to A-Life", withTap(function(check, env, evaluate)
        env.answers = { chain = "regroup", fortify = "fortify" }
        local _, moduleId = evaluate("decision", npc, {}, {})
        check.equal(moduleId, "regroup")
        env.pick = "scavenge"
        local _, held = evaluate("decision", npc, {}, {}, "fortify")
        check.equal(held, "fortify")
        evaluate("positioning", npc, {}, {})
        check.same(env.calls, { "chain", "fortify", "chain" })
        check.equal(#env.taps, 1, "only full decision chains are logged")
    end) },
    { "a chooser that fails leaves the decision to A-Life", withTap(function(check, env, evaluate)
        Hooks.decisionChooser = function() error("boom") end
        env.answers = { chain = "regroup" }
        local _, moduleId = evaluate("response", npc, {}, {})
        check.equal(moduleId, "regroup")
        check.truthy(Hooks.decisionChooserError ~= nil)
    end) },
})

-- Moods: a fake bridge and player key.
local function withMoods(body)
    return function(check)
        local saved = { override = Moods.override, wanted = Moods.wanted, order = Moods.order, askedAtMs = Moods.askedAtMs,
            inflight = Moods.inflight, lastSentMs = Moods.lastSentMs, stats = Moods.stats }
        local env = { now = 900000, requests = {} }
        env.bridge = { online = true, features = { moods = true } }
        function env.bridge:isOnline() return self.online end
        function env.bridge:request(kind, data, callback)
            env.requests[#env.requests + 1] = { kind = kind, data = data, callback = callback }
            return "id" .. #env.requests
        end
        env.hooks = { nowMs = function() return env.now end, playerKey = function() return "sp:0" end }
        Moods.reset()
        Moods.override = { bridge = env.bridge, hooks = env.hooks, player = {} }
        local ok, failure = pcall(body, check, env)
        for key, value in pairs(saved) do Moods[key] = value end
        for uid in pairs(Dialogue.minds) do
            if string.sub(uid, 1, 11) == "test:moods:" then Dialogue.minds[uid] = nil end
        end
        if not ok then error(failure) end
    end
end

ALifeBrain.Tests.suite("Moods", {
    { "asks once for NPCs it does not know and fills their minds", withMoods(function(check, env)
        Dialogue.minds["test:moods:known"] = { trust = 5, fear = 0, goal = 0 }
        Moods.want("test:moods:a", env.now)
        Moods.want("test:moods:a", env.now)
        Moods.want("test:moods:known", env.now)
        Moods.want("test:moods:b", env.now)
        Moods.tick(env.now)
        check.equal(#env.requests, 1)
        local request = env.requests[1]
        check.equal(request.kind, "moods")
        check.same(request.data, { playerKey = "sp:0", uids = { "test:moods:a", "test:moods:b" } })
        Moods.want("test:moods:c", env.now)
        Moods.tick(env.now + Moods.settings.periodMs)
        check.equal(#env.requests, 1, "one request at a time")
        request.callback(true, { moods = { { uid = "test:moods:a", trust = 30, fear = -10, goal = -60 } } })
        local mind = Dialogue.minds["test:moods:a"]
        check.equal(mind.trust, 30)
        check.equal(mind.goal, -60)
        check.isNil(Dialogue.minds["test:moods:b"], "unknown to the sidecar: stays at 0")
        check.equal(Moods.stats.filled, 1)
        Moods.tick(env.now + Moods.settings.periodMs)
        check.same(env.requests[2].data.uids, { "test:moods:c" })
    end) },
    { "an NPC that came back empty is asked again only after a while", withMoods(function(check, env)
        Moods.want("test:moods:d", env.now)
        Moods.tick(env.now)
        env.requests[1].callback(true, { moods = {} })
        Moods.want("test:moods:d", env.now + 1000)
        check.equal(#Moods.order, 0)
        Moods.want("test:moods:d", env.now + Moods.settings.retryMs)
        check.equal(#Moods.order, 1)
    end) },
    { "waits while the sidecar cannot answer", withMoods(function(check, env)
        Moods.want("test:moods:e", env.now)
        env.bridge.features = { dialogue = true }
        Moods.tick(env.now)
        env.bridge.features, env.bridge.online = { moods = true }, false
        Moods.tick(env.now)
        check.equal(#env.requests, 0)
        check.equal(#Moods.order, 1, "still queued")
        env.bridge.online = true
        Moods.tick(env.now)
        env.requests[1].callback(false, "timeout")
        check.equal(Moods.inflight, false)
        check.equal(Moods.stats.failed, 1)
    end) },
})

ALifeBrain.Tests.suite("Drive", {
    { "settles toward 0 with the sidecar's half-life", function(check)
        local mind = { goal = 80, goalAtMs = 1000 }
        check.equal(Dialogue.goalNow(mind, 1000), 80)
        check.truthy(math.abs(Dialogue.goalNow(mind, 1000 + Dialogue.GOAL_HALF_LIFE_MS) - 40) < 1e-6)
        check.equal(Dialogue.goalNow({ goal = 0, goalAtMs = 0 }, 5000000), 0)
        check.equal(Dialogue.goalNow(nil, 1000), 0)
    end },
    { "a reply sets it, a stored mood only fills a mind we do not have", function(check)
        local uid = "test:drive:1"
        local saved = Dialogue.minds[uid]
        local ok, failure = pcall(function()
            Dialogue.minds[uid] = nil
            check.truthy(Dialogue.learnMood(uid, { trust = 10, fear = 0, goal = 300 }, 5))
            check.equal(Dialogue.minds[uid].goal, 100, "clamped")
            check.equal(Dialogue.learnMood(uid, { trust = -50, goal = -20 }, 6), false)
            check.equal(Dialogue.minds[uid].trust, 10)
            Dialogue.remember(uid, { trust = 12, fear = 3, goal = -25, intent = "none" }, 7)
            check.same({ Dialogue.minds[uid].goal, Dialogue.minds[uid].goalAtMs }, { -25, 7 })
        end)
        Dialogue.minds[uid] = saved
        if not ok then error(failure) end
    end },
})
