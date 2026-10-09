require "ALifeBrain/Dialogue"
require "ALifeBrain/Tests/TestRunner"

local Dialogue = ALifeBrain.Dialogue

-- Fake bridge + fake A-Life hooks; every call is recorded in env.calls.
local function harness(options)
    options = options or {}
    local env = { calls = {}, requests = {}, now = 5000, combat = false, stance = options.stance or "neutral",
        talkable = true }
    local function record(name, ...)
        env.calls[#env.calls + 1] = { name, ... }
    end
    env.npc = { uid = "palife:1", memory = {} }
    env.shell = { id = "shell" }
    env.player = { id = "player" }
    env.listener = { record = env.npc, shell = env.shell, distance = 2, inCone = true }

    env.events = {}
    env.inventory = options.inventory or { water = 1, food = 0, medicine = 0 }
    env.bridge = {
        online = options.online ~= false,
        features = options.features or { dialogue = true },
    }
    function env.bridge:isOnline() return self.online end
    function env.bridge:request(kind, data, callback, timeoutMs)
        if options.refuse then return nil, "outbox_full" end
        env.requests[#env.requests + 1] = { kind = kind, data = data, callback = callback, timeoutMs = timeoutMs }
        return "req:" .. #env.requests
    end
    function env.bridge:send(kind, data)
        env.events[#env.events + 1] = { kind = kind, data = data }
        return true
    end

    env.hooks = {
        inCombat = function() return env.combat end,
        stance = function() return env.stance end,
        hold = function(_, _, _, _, ms) record("hold", ms) end,
        say = function(_, text) record("say", text) end,
        dialogueContext = function(npc) return { npc = { uid = npc.uid }, player = { key = "sp:0" } } end,
        readRecord = function(uid) if uid == env.npc.uid then return env.npc end end,
        talkable = function() return env.talkable end,
        nowMs = function() return env.now end,
        respondWithAlife = function(_, listener, text) record("alife", text, listener.record.uid); return "A-Life line" end,
        inventorySummary = function() return env.inventory end,
        followingPlayer = function() return false end,
        playerKey = function() return "sp:0" end,
        describe = function() return { uid = env.npc.uid, name = "Henry" } end,
        quietPresence = function(_, _, ms) record("quiet", ms) end,
        notify = function(_, text, good) record("notify", text, good) end,
        giveItem = function(_, _, _, item)
            if (env.inventory[item] or 0) < 1 then return false, "no_item" end
            env.inventory[item] = env.inventory[item] - 1
            record("give", item)
            return true, "Water Bottle"
        end,
        orderFollow = function(_, _, ms) record("follow", ms); return true end,
        orderStay = function(_, _, ms) record("stay", ms); return true end,
        tradeableItems = function() return env.tradeable or {} end,
        playerTradeableItems = function() return env.playerTradeable or {} end,
        executeTrade = function(_, _, _, offered, asked)
            record("trade", #offered, #asked)
            if env.tradeFails then return false, env.tradeFails end
            local given = {}
            for _, want in ipairs(asked) do given[#given + 1] = want.name end
            local received = {}
            for _, entry in ipairs(offered) do received[#received + 1] = entry.name end
            return true, given, received
        end,
    }

    Dialogue.pending, Dialogue.minds, Dialogue.gives = {}, {}, {}
    Dialogue.metrics = { asked = 0, answered = 0, fallbacks = 0, busy = 0, dropped = 0, actions = 0 }
    Dialogue.override = { bridge = env.bridge, hooks = env.hooks }

    function env.talk(text) return Dialogue.handle(env.player, env.listener, text or "hello", env.now) end
    function env.answer(index, ok, reply) env.requests[index or 1].callback(ok, reply) end
    function env.said()
        local lines = {}
        for _, call in ipairs(env.calls) do if call[1] == "say" then lines[#lines + 1] = call[2] end end
        return lines
    end
    function env.called(name)
        local found = {}
        for _, call in ipairs(env.calls) do if call[1] == name then found[#found + 1] = call end end
        return found
    end
    -- A fake view (chat window) recording its callbacks.
    function env.view()
        local view = { replies = {}, fallbacks = {}, dropped = 0 }
        function view:onReply(say, reply, outcome) self.replies[#self.replies + 1] = { say = say, outcome = outcome } end
        function view:onFallback(reason, said) self.fallbacks[#self.fallbacks + 1] = { reason = reason, said = said } end
        function view:onDropped() self.dropped = self.dropped + 1 end
        return view
    end
    function env.done()
        Dialogue.override = nil
        Dialogue.pending, Dialogue.minds, Dialogue.gives, Dialogue.lastError = {}, {}, {}, nil
        Dialogue.metrics = { asked = 0, answered = 0, fallbacks = 0, busy = 0, dropped = 0, actions = 0 }
    end
    return env
end

local function run(options, body)
    local env = harness(options)
    local ok, err = pcall(body, env)
    env.done()
    if not ok then error(err, 0) end
end

ALifeBrain.Tests.suite("Dialogue", {
    { "asks the sidecar and shows a thinking bubble", function(check) run(nil, function(env)
        local said, reason = env.talk("Got any water?")
        check.equal(said, "...")
        check.equal(reason, "llm_pending")
        check.equal(#env.requests, 1)
        check.equal(env.requests[1].kind, "dialogue")
        check.equal(env.requests[1].data.text, "Got any water?")
        check.equal(env.requests[1].data.stance, "neutral")
        check.equal(env.requests[1].data.npc.uid, "palife:1")
        check.same(env.said(), { "..." })
        check.equal(env.calls[1][1], "hold", "the NPC stops before the bubble")
    end) end },

    { "speaks the reply and remembers trust and fear", function(check) run(nil, function(env)
        env.talk()
        env.answer(1, true, { say = "  Keep\nback.  ", trust = 12, fear = 140, intent = "warn" })
        check.same(env.said(), { "...", "Keep back." })
        check.same(Dialogue.minds["palife:1"], { trust = 12, fear = 100, intent = "warn", atMs = 5000 })
        check.equal(Dialogue.metrics.answered, 1)
        check.isNil(Dialogue.pending["palife:1"])
    end) end },

    { "falls back to A-Life when the sidecar fails", function(check) run(nil, function(env)
        env.talk("hello there")
        env.answer(1, false, "timeout")
        local last = env.calls[#env.calls]
        check.same(last, { "alife", "hello there", "palife:1" })
        check.equal(Dialogue.metrics.fallbacks, 1)
        check.equal(Dialogue.lastError, "timeout")
    end) end },

    { "falls back on an empty or malformed reply", function(check) run(nil, function(env)
        env.talk()
        env.answer(1, true, { say = "   " })
        check.equal(env.calls[#env.calls][1], "alife")
    end) end },

    { "unknown intents become none", function(check) run(nil, function(env)
        env.talk()
        env.answer(1, true, { say = "Sure.", intent = "launch_nukes" })
        check.equal(Dialogue.minds["palife:1"].intent, "none")
    end) end },

    { "leaves combat, hostile and offline cases to A-Life", function(check)
        run({ online = false }, function(env) check.isNil(env.talk()) end)
        run({ features = { ping = true } }, function(env) check.isNil(env.talk(), "sidecar without dialogue") end)
        run({ stance = "hostile" }, function(env) check.isNil(env.talk()) end)
        run(nil, function(env)
            env.combat = true
            check.isNil(env.talk())
            check.equal(#env.requests, 0)
        end)
        run({ refuse = true }, function(env)
            check.isNil(env.talk(), "request refused")
            check.equal(#env.calls, 0, "no bubble when nothing was sent")
        end)
    end },

    { "does not stack requests while the NPC is thinking", function(check) run(nil, function(env)
        env.talk("one")
        local said, reason = env.talk("two")
        check.equal(said, "...")
        check.equal(reason, "llm_busy")
        check.equal(#env.requests, 1)
        env.answer(1, true, { say = "Answer one." })
        env.talk("three")
        check.equal(#env.requests, 2, "free again after the reply")
    end) end },

    { "keeps showing the thinking bubble while waiting", function(check) run(nil, function(env)
        env.talk()
        Dialogue.tick(env.now + 1000)
        check.same(env.said(), { "..." }, "not yet")
        Dialogue.tick(env.now + Dialogue.settings.thinkingRepeatMs)
        check.same(env.said(), { "...", "..." })
        Dialogue.tick(env.now + Dialogue.settings.thinkingRepeatMs + 1000)
        check.same(env.said(), { "...", "..." }, "once per interval")
        env.answer(1, true, { say = "Done." })
        Dialogue.tick(env.now + 60000)
        check.same(env.said(), { "...", "...", "Done." }, "stops after the reply")
    end) end },

    { "drops replies for NPCs that died or left", function(check) run(nil, function(env)
        env.talk()
        env.talkable = false
        env.answer(1, true, { say = "Too late." })
        check.same(env.said(), { "..." })
        check.equal(Dialogue.metrics.dropped, 1)
    end) end },

    { "sends inventory and follow state with the request", function(check) run(nil, function(env)
        env.talk("got water?")
        check.same(env.requests[1].data.npc.inventory, { water = 1, food = 0, medicine = 0 })
        check.equal(env.requests[1].data.npc.following, false)
    end) end },

    { "gives a real item and reports it", function(check) run(nil, function(env)
        local view = env.view()
        Dialogue.ask(env.player, env.npc, env.shell, "water please", view)
        env.answer(1, true, { say = "Here.", intent = "give", item = "water", trust = 5 })
        check.equal(#env.called("give"), 1)
        check.equal(env.inventory.water, 0)
        local outcome = view.replies[1].outcome
        check.same(outcome, { action = "give", ok = true, item = "water", label = "Water Bottle" })
        check.equal(env.events[1].data.kind, "npc_action")
        check.equal(env.events[1].data.ok, true)
        check.equal(env.events[1].data.label, "Water Bottle")
        check.same(env.events[1].data.by, { kind = "player", key = "sp:0" })
    end) end },

    { "reports a promise the NPC cannot keep", function(check) run({ inventory = { water = 0 } }, function(env)
        local view = env.view()
        Dialogue.ask(env.player, env.npc, env.shell, "water please", view)
        env.answer(1, true, { say = "Sure, take it.", intent = "give", item = "water" })
        check.same(view.replies[1].outcome, { action = "give", ok = false, item = "water", reason = "no_item" })
        check.equal(env.events[1].data.reason, "no_item")
    end) end },

    { "limits how much one player can take", function(check) run({ inventory = { water = 9 } }, function(env)
        local results = {}
        for index = 1, 5 do
            local view = env.view()
            env.now = env.now + Dialogue.limits.giveCooldownMs
            Dialogue.ask(env.player, env.npc, env.shell, "more", view)
            env.answer(index, true, { say = "Here.", intent = "give", item = "water" })
            results[index] = view.replies[1].outcome.ok
        end
        check.same(results, { true, true, true, false, false })
        check.equal(env.inventory.water, 6)
        env.now = env.now + 3600000
        local view = env.view()
        Dialogue.ask(env.player, env.npc, env.shell, "later", view)
        env.answer(6, true, { say = "Here.", intent = "give", item = "water" })
        check.equal(view.replies[1].outcome.ok, true, "the hourly limit resets")
    end) end },

    { "ignores give without a known item", function(check) run(nil, function(env)
        local view = env.view()
        Dialogue.ask(env.player, env.npc, env.shell, "gun?", view)
        env.answer(1, true, { say = "Here.", intent = "give", item = "rifle" })
        check.isNil(view.replies[1].outcome)
        check.equal(#env.events, 0)
    end) end },

    { "follows only with enough trust or a friendly stance", function(check)
        run(nil, function(env)
            local view = env.view()
            Dialogue.ask(env.player, env.npc, env.shell, "come with me", view)
            env.answer(1, true, { say = "Lead on.", intent = "follow", trust = 2 })
            check.same(view.replies[1].outcome, { action = "follow", ok = false, reason = "low_trust" })
            check.equal(#env.called("follow"), 0)
        end)
        run(nil, function(env)
            local view = env.view()
            Dialogue.ask(env.player, env.npc, env.shell, "come with me", view)
            env.answer(1, true, { say = "Lead on.", intent = "follow", trust = 15 })
            check.same(view.replies[1].outcome, { action = "follow", ok = true, minutes = 10 })
            check.equal(env.called("follow")[1][2], Dialogue.limits.followMs)
        end)
        run({ stance = "friendly" }, function(env)
            local view = env.view()
            Dialogue.ask(env.player, env.npc, env.shell, "come with me", view)
            env.answer(1, true, { say = "Lead on.", intent = "follow", trust = 0 })
            check.equal(view.replies[1].outcome.ok, true)
        end)
    end },

    { "stay and leave", function(check) run(nil, function(env)
        local view = env.view()
        Dialogue.ask(env.player, env.npc, env.shell, "wait here", view)
        env.answer(1, true, { say = "I'll wait.", intent = "stay" })
        check.same(view.replies[1].outcome, { action = "stay", ok = true })
        Dialogue.ask(env.player, env.npc, env.shell, "bye", view)
        env.answer(2, true, { say = "Bye.", intent = "leave" })
        check.same(view.replies[2].outcome, { action = "leave", ok = true })
    end) end },

    { "talk box replies quiet A-Life's greetings; the window does not", function(check) run(nil, function(env)
        env.talk()
        env.answer(1, true, { say = "Hi." })
        check.equal(#env.called("quiet"), 1)
        Dialogue.ask(env.player, env.npc, env.shell, "hi", env.view())
        env.answer(2, true, { say = "Hi." })
        check.equal(#env.called("quiet"), 1, "the window quiets A-Life when it closes")
    end) end },

    { "the talk box shows what really happened above the player", function(check) run(nil, function(env)
        local forced = ALifeBrain.Text.forced
        ALifeBrain.Text.forced = "EN"
        env.talk("water?")
        env.answer(1, true, { say = "Here.", intent = "give", item = "water" })
        ALifeBrain.Text.forced = forced
        local notes = env.called("notify")
        check.equal(#notes, 1)
        check.equal(notes[1][2], "Henry gave you: Water Bottle (added to your inventory)")
        check.equal(notes[1][3], true)
        Dialogue.ask(env.player, env.npc, env.shell, "more?", env.view())
        env.now = env.now + Dialogue.limits.giveCooldownMs
        env.answer(2, true, { say = "Here.", intent = "give", item = "water" })
        check.equal(#env.called("notify"), 1, "the window shows outcomes itself")
    end) end },

    { "the window hears about fallbacks and dropped replies", function(check) run(nil, function(env)
        local view = env.view()
        Dialogue.ask(env.player, env.npc, env.shell, "hello", view)
        env.answer(1, false, "rate_limited")
        check.same(view.fallbacks, { { reason = "rate_limited", said = "A-Life line" } })
        Dialogue.ask(env.player, env.npc, env.shell, "hello", view)
        env.talkable = false
        env.answer(2, true, { say = "Hm." })
        check.equal(view.dropped, 1)
    end) end },

    { "ask explains why it did not send", function(check)
        run({ online = false }, function(env) check.same({ Dialogue.ask(env.player, env.npc, env.shell, "x") }, { nil, "offline" }) end)
        run({ stance = "hostile" }, function(env) check.same({ Dialogue.ask(env.player, env.npc, env.shell, "x") }, { nil, "hostile" }) end)
        run(nil, function(env)
            env.combat = true
            check.same({ Dialogue.ask(env.player, env.npc, env.shell, "x") }, { nil, "combat" })
        end)
        run(nil, function(env)
            Dialogue.ask(env.player, env.npc, env.shell, "one")
            check.same({ Dialogue.ask(env.player, env.npc, env.shell, "two") }, { nil, "busy" })
        end)
    end },

    { "puts the trade table in front of the NPC", function(check) run(nil, function(env)
        env.tradeable = { { type = "Base.Beans", name = "Beans", count = 2 } }
        env.playerTradeable = { { type = "Base.Nails", name = "Nails", count = 5 } }
        local trade = ALifeBrain.Trade.new(function(entry) return entry end)
        trade:offer({ { id = 1, type = "Base.Bandage", name = "Bandage" } })
        Dialogue.ask(env.player, env.npc, env.shell, "deal?", env.view(), trade)
        local data = env.requests[1].data
        check.same(data.npc.tradeable, { { name = "Beans", count = 2 } })
        check.same(data.trade.playerOffer, { { name = "Bandage", count = 1 } })
        check.same(data.player.tradeable, { { name = "Nails", count = 5 } }, "the NPC may ask for these")
        check.equal(data.player.key, "sp:0")
        Dialogue.ask(env.player, { uid = "other" }, env.shell, "hi", nil, ALifeBrain.Trade.new(function(e) return e end))
        check.isNil(env.requests[2].data.trade, "an empty table is not sent")
        check.same(env.requests[2].data.player.tradeable, { { name = "Nails", count = 5 } })
        Dialogue.ask(env.player, { uid = "third" }, env.shell, "hi", nil, nil)
        check.isNil(env.requests[3].data.player.tradeable, "no table, nothing to ask for")
    end) end },

    { "the NPC accepts and the table swaps", function(check) run(nil, function(env)
        local trade = ALifeBrain.Trade.new(function(entry) return entry end)
        trade:offer({ { id = 1, type = "Base.Bandage", name = "Bandage" } })
        trade:ask({ type = "Base.Beans", name = "Beans", count = 2 })
        local view = env.view()
        Dialogue.ask(env.player, env.npc, env.shell, "deal?", view, trade)
        env.answer(1, true, { say = "Deal.", intent = "trade", trade = { decision = "accept" } })
        local outcome = view.replies[1].outcome
        check.equal(outcome.ok, true)
        check.same(outcome.given, { "Beans" })
        check.same(outcome.received, { "Bandage" })
        check.truthy(trade:isEmpty(), "the table is cleared after the swap")
        check.equal(env.events[1].data.action, "trade")
        check.same(env.events[1].data.received, { "Bandage" })
    end) end },

    { "a changed table is not swapped", function(check) run(nil, function(env)
        local trade = ALifeBrain.Trade.new(function(entry) return entry end)
        trade:offer({ { id = 1, type = "Base.Bandage", name = "Bandage" } })
        local view = env.view()
        Dialogue.ask(env.player, env.npc, env.shell, "deal?", view, trade)
        trade:offer({ { id = 2, type = "Base.Nails", name = "Nails" } })
        env.answer(1, true, { say = "Deal.", trade = { decision = "accept" } })
        check.same(view.replies[1].outcome, { action = "trade", decision = "accept", ok = false, reason = "changed" })
        check.equal(#env.called("trade"), 0)
    end) end },

    { "reject and counter", function(check) run(nil, function(env)
        local trade = ALifeBrain.Trade.new(function(entry) return entry end)
        trade:offer({ { id = 1, type = "Base.Bandage", name = "Bandage" } })
        local view = env.view()
        Dialogue.ask(env.player, env.npc, env.shell, "deal?", view, trade)
        env.answer(1, true, { say = "No.", trade = { decision = "reject" } })
        check.equal(view.replies[1].outcome.reason, "rejected")
        check.equal(env.events[1].data.reason, "rejected")
        Dialogue.ask(env.player, env.npc, env.shell, "something else?", view, trade)
        env.answer(2, true, { say = "Beans?", trade = { decision = "counter", npcOffer = { "Beans", 5 },
            npcWants = { "Nails", false } } })
        check.same(view.replies[2].outcome, { action = "trade", decision = "counter", ok = true, offer = { "Beans" },
            wants = { "Nails" } })
        check.equal(#env.events, 1, "a counter-offer is not an outcome yet")
    end) end },

    { "a counter in A-Life's talk box is only words", function(check) run(nil, function(env)
        env.talk("trade?")
        env.answer(1, true, { say = "Beans for nails.", trade = { decision = "counter", npcOffer = { "Beans" },
            npcWants = { "Nails" } } })
        check.equal(#env.called("trade"), 0, "nothing changes hands")
        check.equal(#env.called("notify"), 1, "the player is told to open the window")
    end) end },

    { "an unpaid accept leaves the table as it is", function(check) run(nil, function(env)
        local trade = ALifeBrain.Trade.new(function(entry) return entry end)
        trade:ask({ type = "Base.Beans", name = "Beans", count = 2 })
        local view = env.view()
        env.tradeFails = "unpaid"
        Dialogue.ask(env.player, env.npc, env.shell, "give me beans, I'll pay later", view, trade)
        env.answer(1, true, { say = "Fine.", trade = { decision = "accept" } })
        check.equal(view.replies[1].outcome.reason, "unpaid")
        check.equal(env.events[1].data.reason, "unpaid", "the NPC remembers")
        check.equal(trade:askedCount("Base.Beans"), 2, "the table stays for the player to pay")
    end) end },

    { "accepting a counter-offer needs no new round", function(check) run(nil, function(env)
        local trade = ALifeBrain.Trade.new(function(entry) return entry end)
        trade:offer({ { id = 1, type = "Base.Bandage", name = "Bandage" } })
        trade:applyCounter({ "Beans" }, { { type = "Base.Beans", name = "Beans", count = 2 } })
        local outcome = Dialogue.executeTrade(env.player, env.npc, env.shell, trade)
        check.equal(outcome.ok, true)
        check.same(outcome.given, { "Beans" })
        check.equal(#env.requests, 0)
        env.tradeFails = "too_far"
        trade:offer({ { id = 2, type = "Base.Nails", name = "Nails" } })
        check.equal(Dialogue.executeTrade(env.player, env.npc, env.shell, trade).reason, "too_far")
        check.equal(Dialogue.executeTrade(env.player, env.npc, env.shell, ALifeBrain.Trade.new()).reason, "empty")
    end) end },

    { "keeps long replies bounded", function(check) run(nil, function(env)
        env.talk()
        env.answer(1, true, { say = string.rep("a", 400) })
        local said = env.said()
        check.equal(#said[2], Dialogue.settings.maxSay + 3)
    end) end },
})
