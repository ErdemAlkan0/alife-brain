require "ALifeBrain/Json"
require "ALifeBrain/Dialogue"
require "ALifeBrain/Moods"
require "ALifeBrain/Control"
require "ALifeBrain/Keeper"
require "ALifeBrain/Pause"
require "ALifeBrain/Robberies"
require "ALifeBrain/Rapport"
require "ALifeBrain/ALifeBrainHooks"
require "ALifeBrain/Tests/TestRunner"

local Json, Dialogue, Moods, Control, Hooks, Keeper, Pause, Robberies = ALifeBrain.Json, ALifeBrain.Dialogue,
    ALifeBrain.Moods, ALifeBrain.Control, ALifeBrain.Hooks, ALifeBrain.Keeper, ALifeBrain.Pause, ALifeBrain.Robberies
local Rapport = ALifeBrain.Rapport

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
    { "follows the tick box, or the saved value without one", withControl(function(check, env)
        local savedOption, savedValue = Control.option, Control.saved
        local ok, failure = pcall(function()
            Control.forced = nil
            Control.option = { value = true, getValue = function(self) return self.value end }
            check.equal(Control.enabled(), true)
            Control.option.value = false
            Control.saved = true
            check.equal(Control.enabled(), false, "the tick box wins")
            Control.option = nil
            check.equal(Control.enabled(), true, "no tick box: ModOptions.ini")
            Control.saved = nil
            check.equal(Control.enabled(), false)
        end)
        Control.option, Control.saved = savedOption, savedValue
        if not ok then error(failure) end
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

-- Keeper: fake hooks around A-Life's registry.
local function withKeeper(body)
    return function(check)
        local saved = { override = Keeper.override, done = Keeper.done, lastMs = Keeper.lastMs, warnedCap = Keeper.warnedCap,
            groups = Keeper.groups, cap = Keeper.cap, stats = Keeper.stats, option = Keeper.option, savedValue = Keeper.saved }
        local env = { near = {}, results = {}, calls = {}, warnings = {}, groups = 1, cap = 20 }
        env.hooks = {
            actorsNearPlayers = function(tiles) env.tiles = tiles; return env.near end,
            keepGroupOf = function(uid)
                env.calls[#env.calls + 1] = uid
                local result = env.results[uid] or { "kept", 3 }
                return result[1], result[2]
            end,
            savedGroups = function() return env.groups, env.cap, 1 end,
        }
        Keeper.reset()
        Keeper.option, Keeper.saved = nil, nil
        Keeper.override = { hooks = env.hooks, warn = function(text) env.warnings[#env.warnings + 1] = text end }
        local ok, failure = pcall(body, check, env)
        Keeper.override, Keeper.done, Keeper.lastMs, Keeper.warnedCap = saved.override, saved.done, saved.lastMs, saved.warnedCap
        Keeper.groups, Keeper.cap, Keeper.stats, Keeper.option, Keeper.saved = saved.groups, saved.cap, saved.stats,
            saved.option, saved.savedValue
        if not ok then error(failure) end
    end
end

ALifeBrain.Tests.suite("Keeper", {
    { "keeps an NPC that comes within 10 tiles, once", withKeeper(function(check, env)
        env.near = { "palife:1" }
        Keeper.tick(10000)
        check.equal(env.tiles, 10)
        check.same(env.calls, { "palife:1" })
        check.same({ Keeper.stats.kept, Keeper.stats.npcs }, { 1, 3 }, "with its group")
        Keeper.tick(10000 + Keeper.settings.periodMs)
        check.equal(#env.calls, 1, "never asked again, even while it stays close")
        env.near = {}
        Keeper.tick(10000 + 2 * Keeper.settings.periodMs)
        check.equal(#env.calls, 1)
    end) },
    { "does not ask more often than its period", withKeeper(function(check, env)
        env.near = { "palife:1" }
        Keeper.tick(10000)
        env.near = { "palife:2" }
        Keeper.tick(10500)
        check.same(env.calls, { "palife:1" })
        Keeper.tick(10000 + Keeper.settings.periodMs)
        check.same(env.calls, { "palife:1", "palife:2" })
    end) },
    { "leaves A-Life's own alone and retries a failed write later", withKeeper(function(check, env)
        env.near = { "palife:a", "palife:m", "palife:x", "palife:f" }
        env.results = { ["palife:a"] = { "already" }, ["palife:m"] = { "managed" }, ["palife:x"] = { nil, "dead" },
            ["palife:f"] = { nil, "write_failed" } }
        Keeper.tick(10000)
        check.same({ Keeper.stats.already, Keeper.stats.managed, Keeper.stats.failed, Keeper.stats.kept }, { 1, 1, 1, 0 })
        Keeper.tick(10000 + Keeper.settings.periodMs)
        check.equal(#env.calls, 4, "nothing asked again before the retry time")
        env.results["palife:f"] = nil
        Keeper.tick(10000 + Keeper.settings.retryMs)
        check.equal(env.calls[#env.calls], "palife:f")
        check.equal(Keeper.stats.kept, 1)
    end) },
    { "warns once when A-Life would save fewer groups than are kept", withKeeper(function(check, env)
        env.groups, env.cap = 21, 20
        env.near = { "palife:1" }
        Keeper.tick(10000)
        env.near = { "palife:2" }
        Keeper.tick(10000 + Keeper.settings.periodMs)
        check.equal(#env.warnings, 1)
        check.truthy(string.find(env.warnings[1], "20", 1, true) ~= nil)
        check.same({ Keeper.groups, Keeper.cap }, { 21, 20 })
    end) },
    { "the tick box turns it off; on without one unless saved off", withKeeper(function(check, env)
        env.near = { "palife:1" }
        Keeper.option = { value = false, getValue = function(self) return self.value end }
        Keeper.tick(10000)
        check.equal(#env.calls, 0)
        Keeper.option = nil
        check.equal(Keeper.enabled(), true, "on by default")
        Keeper.saved = false
        check.equal(Keeper.enabled(), false)
    end) },
})

-- Pause: a fake speed control.
local function withPause(body)
    return function(check)
        local saved = { override = Pause.override, held = Pause.held, option = Pause.option, savedValue = Pause.saved }
        local env = { speed = 1, shown = {}, mp = false }
        Pause.held, Pause.option, Pause.saved = nil, nil, nil
        Pause.override = {
            speed = function() return env.speed end,
            setSpeed = function(speed) env.speed = speed end,
            showMessage = function(show) env.shown[#env.shown + 1] = show end,
            multiplayer = function() return env.mp end,
        }
        local ok, failure = pcall(body, check, env)
        Pause.override, Pause.held, Pause.option, Pause.saved = saved.override, saved.held, saved.option, saved.savedValue
        if not ok then error(failure) end
    end
end

ALifeBrain.Tests.suite("Pause", {
    { "pauses for the conversation and brings the old speed back", withPause(function(check, env)
        env.speed = 3
        check.equal(Pause.hold(), true)
        check.equal(env.speed, 0)
        check.equal(Pause.active(), true)
        check.equal(Pause.hold(), false, "one window at a time")
        check.equal(Pause.release(), true)
        check.equal(env.speed, 3)
        check.same(env.shown, { false, true }, "the window says it is paused, not the banner")
        check.equal(Pause.release(), false)
    end) },
    { "a game already paused stays paused", withPause(function(check, env)
        env.speed = 0
        check.equal(Pause.hold(), false)
        Pause.release()
        check.equal(env.speed, 0)
    end) },
    { "the player's own speed change wins", withPause(function(check, env)
        Pause.hold()
        env.speed = 2 -- unpaused by hand while talking
        check.equal(Pause.active(), false)
        Pause.release()
        check.equal(env.speed, 2)
    end) },
    { "never in multiplayer, never when switched off", withPause(function(check, env)
        env.mp = true
        check.equal(Pause.hold(), false)
        env.mp = false
        Pause.option = { value = false, getValue = function(self) return self.value end }
        check.equal(Pause.hold(), false)
        check.equal(env.speed, 1)
        Pause.option = nil
        check.equal(Pause.enabled(), true, "on by default")
    end) },
})

ALifeBrain.Tests.suite("Robberies", {
    { "reports how a robbery ended, once, with the crew and what was taken", function(check)
        local saved = { override = Robberies.override, seen = Robberies.seen, lastMs = Robberies.lastMs, stats = Robberies.stats }
        local ok, failure = pcall(function()
            local active, sent = {}, {}
            Robberies.seen, Robberies.lastMs, Robberies.stats = {}, 0, { seen = 0, reported = 0 }
            Robberies.override = {
                hooks = {
                    activeRobberies = function() return active end,
                    describeRecord = function(uid) return { uid = uid, name = "Name of " .. uid } end,
                    itemName = function(fullType) return (string.gsub(fullType, "^Base%.", "")) end,
                    playerKey = function() return "sp:0" end,
                },
                emit = function(kind, fields) sent[#sent + 1] = { kind = kind, fields = fields }; return true end,
            }
            local state = { members = { "palife:a", "palife:b" }, leaderUid = "palife:a", player = {}, phase = "search" }
            active["robbery:1"] = state
            Robberies.tick(1000)
            check.equal(#sent, 0, "still going")
            Robberies.tick(1500)
            check.equal(#sent, 0, "not before its period")
            active["robbery:1"] = nil
            state.finishedReason, state.taken = "released", { "Base.Hammer" }
            Robberies.tick(2000)
            check.equal(#sent, 1)
            local fields = sent[1].fields
            check.equal(sent[1].kind, "robbed_player")
            check.same({ fields.npc.uid, #fields.crew, fields.outcome, fields.taken[1], fields.by.key },
                { "palife:a", 2, "released", "Hammer", "sp:0" })
            Robberies.tick(3000)
            check.equal(#sent, 1, "reported once")
        end)
        for key, value in pairs(saved) do Robberies[key] = value end
        if not ok then error(failure) end
    end },
})

-- Rapport: fake A-Life records, stance (careful unless env.stances says otherwise; tolerated
-- reads as neutral, as in Relations.playerStance) and Talk.tolerate.
local function withRapport(body)
    return function(check)
        local saved = { override = Rapport.override, granted = Rapport.granted, lastMs = Rapport.lastMs, stats = Rapport.stats }
        local env = { now = 100000, minds = {}, stances = {}, tolerated = {}, writes = {}, logs = {}, player = { id = "player" } }
        env.records = {
            ["palife:a"] = { uid = "palife:a", name = "Hunter", lifecycle = "active", memory = { groupId = "g1" } },
            ["palife:b"] = { uid = "palife:b", name = "Scrapper", lifecycle = "active", memory = { groupId = "g1" } },
            ["palife:c"] = { uid = "palife:c", name = "Biker", lifecycle = "active", memory = { groupId = "g2" } },
        }
        env.hooks = {
            peekRecord = function(uid) return env.records[uid] end,
            groupKey = Hooks.groupKey,
            stance = function(record)
                local key = Hooks.groupKey(record)
                local base, untilMs = env.stances[key] or "careful", env.tolerated[key]
                if base == "careful" and untilMs ~= nil and env.now < untilMs then return "neutral" end
                return base
            end,
            toleratedUntil = function(record) return env.tolerated[Hooks.groupKey(record)] end,
            tolerate = function(record, _, untilMs)
                if env.fail then return false end
                env.writes[#env.writes + 1] = { Hooks.groupKey(record), untilMs }
                env.tolerated[Hooks.groupKey(record)] = untilMs
                return true
            end,
            nameOf = function(record) return record.name end,
        }
        function env.trust(uid, value) env.minds[uid] = { trust = value } end
        function env.tick(ms)
            env.now = env.now + (ms or Rapport.settings.periodMs)
            Rapport.tick(env.now)
        end
        Rapport.reset()
        Rapport.override = { hooks = env.hooks, minds = env.minds, player = env.player,
            log = function(text) env.logs[#env.logs + 1] = text end }
        local ok, failure = pcall(body, check, env)
        for key, value in pairs(saved) do Rapport[key] = value end
        if not ok then error(failure) end
    end
end

ALifeBrain.Tests.suite("Rapport", {
    { "an NPC that trusts the player lets them close to its careful group", withRapport(function(check, env)
        env.trust("palife:a", Rapport.settings.trust - 1)
        env.tick()
        check.equal(#env.writes, 0, "not yet")
        env.trust("palife:a", Rapport.settings.trust)
        env.tick()
        check.same(env.writes, { { "g1", env.now + Rapport.settings.holdMs } }, "the whole group, through A-Life")
        check.truthy(Rapport.vouches(env.records["palife:b"], env.now), "the rest of the group too")
        check.equal(Rapport.vouches(env.records["palife:c"], env.now), false)
        check.equal(#env.logs, 1)
        env.tick()
        check.equal(#env.writes, 1, "written once, not every tick")
    end) },
    { "renews while the trust holds and takes back only its own grant", withRapport(function(check, env)
        env.trust("palife:a", 6)
        env.tick()
        env.tick(Rapport.settings.holdMs - Rapport.settings.renewMs)
        check.equal(#env.writes, 2, "renewed before it ran out")
        check.equal(Rapport.stats.renewed, 1)
        env.trust("palife:a", Rapport.settings.keepTrust)
        env.tick()
        check.equal(#env.writes, 2, "a trust that wobbles below the line stays")
        env.trust("palife:a", Rapport.settings.keepTrust - 1)
        env.tick()
        check.same(env.writes[3], { "g1", env.now }, "withdrawn")
        check.equal(Rapport.vouches(env.records["palife:a"], env.now), false)
        check.equal(env.hooks.stance(env.records["palife:a"]), "careful")
        env.trust("palife:a", 6)
        env.tick()
        env.tolerated.g1 = env.now + 99999999 -- A-Life's own, longer (a walk together)
        env.trust("palife:a", 0)
        env.tick()
        check.equal(#env.writes, 4, "A-Life's tolerance is left alone")
        check.equal(Rapport.stats.withdrawn, 1)
    end) },
    { "the best trust in a group counts; other stances are left alone", withRapport(function(check, env)
        env.trust("palife:a", -20)
        env.trust("palife:b", 8)
        env.stances.g2 = "hostile"
        env.trust("palife:c", 50)
        env.tick()
        check.same(env.writes, { { "g1", env.now + Rapport.settings.holdMs } })
        env.stances.g2 = "neutral"
        env.tick()
        check.equal(#env.writes, 1, "a neutral group has no warnings to stop")
        env.records["palife:b"].lifecycle = "dead"
        env.tick()
        check.same(env.writes[2], { "g1", env.now }, "the one who vouched died")
    end) },
    { "a reply acts on its group at once; a failed write is tried again", withRapport(function(check, env)
        env.fail = true
        env.trust("palife:a", 7)
        check.isNil(Rapport.onReply("palife:a", env.now))
        env.fail = false
        check.equal(Rapport.onReply("palife:a", env.now), "granted")
        check.isNil(Rapport.onReply("palife:a", env.now), "nothing new")
        check.isNil(Rapport.onReply("palife:unknown", env.now))
        env.trust("palife:a", 1)
        check.equal(Rapport.onReply("palife:b", env.now), "withdrawn", "any member of the group")
        Rapport.override.player = nil
        env.trust("palife:a", 9)
        check.isNil(Rapport.onReply("palife:a", env.now), "no player, nothing to do")
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
