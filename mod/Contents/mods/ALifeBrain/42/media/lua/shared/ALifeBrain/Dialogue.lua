-- LLM dialogue: answers the player's words through the sidecar instead of A-Life's canned
-- lines, then carries out whitelisted intents (give / follow / stay / leave) through A-Life.
--
-- Two entry points share Dialogue.ask:
--   * Dialogue.handle: A-Life's own talk box (Talk.respond hook, speech bubbles only)
--   * ALifeBrain.Chat: the conversation window (passes itself as the "view")
-- Any failure (offline, timeout, invalid reply) falls back to A-Life's own answer, and
-- combat / hostile NPCs are always left to A-Life.

require "ALifeBrain/Json"
require "ALifeBrain/Text"
require "ALifeBrain/Trade"
require "ALifeBrain/Rapport"

ALifeBrain = ALifeBrain or {}

local Dialogue = {
    settings = {
        enabled = true,
        -- Player2 answers in 11 s on average, on a slow evening in up to 43 s; the sidecar gives up
        -- at 60 s (config dialogue.timeout_s) and always answers first, so this only matters if it
        -- is gone. It was 35 s: a reply that came in at 43 s was lost (play test, 2026-10-12).
        timeoutMs = 75000,
        thinkHoldMs = 76000,
        replyHoldMs = 12000,
        quietAfterMs = 180000,
        thinkingText = "...",
        thinkingRepeatMs = 4000,
        maxSay = 240,
    },
    limits = {
        givesPerHour = 3,
        giveCooldownMs = 20000,
        followMs = 600000,
        stayMs = 600000,
        -- The LLM agrees to follow (it sees the trust); the game only refuses an NPC that
        -- distrusts the player or is hostile. It was 10: the LLM moves trust 1-3 per reply, so
        -- NPCs said "let's move" and stayed put (play test, 2026-10-11).
        followTrust = 0,
    },
    -- Mirrors sidecar dialogue.INTENTS / ACTIONS / ITEMS; anything else is treated as "none".
    INTENTS = { none = true, give = true, follow = true, stay = true, leave = true, trade = true, warn = true,
        attack = true, rob = true, give_info = true },
    ACTIONS = { give = true, follow = true, stay = true, leave = true, trade = true },
    TRADE_DECISIONS = { accept = true, reject = true, counter = true },
    ITEMS = { water = true, food = true, medicine = true },
    pending = {},
    minds = {},
    gives = {},
    metrics = { asked = 0, answered = 0, fallbacks = 0, busy = 0, dropped = 0, actions = 0 },
    lastError = nil,
}
ALifeBrain.Dialogue = Dialogue

-- Tests replace this with fakes: { bridge = ..., hooks = ... }.
Dialogue.override = nil

local function deps()
    if Dialogue.override ~= nil then return Dialogue.override end
    return { bridge = ALifeBrain.bridge, hooks = ALifeBrain.Hooks, moods = ALifeBrain.Moods }
end

function Dialogue.supported(bridge)
    bridge = bridge or deps().bridge
    return bridge ~= nil and bridge:isOnline() and type(bridge.features) == "table" and bridge.features.dialogue == true
end

local function clamp(value, low, high)
    value = tonumber(value)
    if value == nil then return nil end
    if value < low then return low end
    if value > high then return high end
    return value
end

-- The sidecar already validates; the game checks again before anything is shown.
function Dialogue.cleanSay(reply)
    if type(reply) ~= "table" or type(reply.say) ~= "string" then return nil end
    local say = string.gsub(reply.say, "%c", " ")
    say = string.gsub(say, "^%s+", "")
    say = string.gsub(say, "%s+$", "")
    if say == "" then return nil end
    if #say > Dialogue.settings.maxSay then say = string.sub(say, 1, Dialogue.settings.maxSay) .. "..." end
    return say
end

-- The NPC's drive (goal: -100 lie low .. 100 go out for supplies and risks) settles back to 0
-- with this half-life, the same as the sidecar's (memory.GOAL_HALF_LIFE_MS).
Dialogue.GOAL_HALF_LIFE_MS = 1800000

-- Per-NPC state the RL policy reads (Hooks.decisionObservation): trust / fear toward the
-- player and the drive, as the sidecar stored them after this reply; last intent.
function Dialogue.remember(uid, reply, now)
    local intent = type(reply.intent) == "string" and Dialogue.INTENTS[reply.intent] and reply.intent or "none"
    Dialogue.minds[uid] = {
        trust = clamp(reply.trust, -100, 100) or 0,
        fear = clamp(reply.fear, -100, 100) or 0,
        goal = clamp(reply.goal, -100, 100) or 0,
        goalAtMs = now,
        intent = intent,
        atMs = now,
    }
    return Dialogue.minds[uid]
end

-- Stored moods of NPCs not talked to in this session (Moods.lua, the chat window's history):
-- fills only minds we do not have, a reply from this session is always fresher.
function Dialogue.learnMood(uid, mood, now)
    if type(uid) ~= "string" or type(mood) ~= "table" or Dialogue.minds[uid] ~= nil then return false end
    Dialogue.minds[uid] = {
        trust = clamp(mood.trust, -100, 100) or 0,
        fear = clamp(mood.fear, -100, 100) or 0,
        goal = clamp(mood.goal, -100, 100) or 0,
        goalAtMs = now,
        intent = "none",
        atMs = now,
        stored = true,
    }
    return true
end

-- The sidecar's stored mood after an event changed it (Moods.refresh): replaces trust, fear and
-- drive of a known mind (its last intent stays), fills an unknown one.
function Dialogue.updateMood(uid, mood, now)
    local mind = Dialogue.minds[uid]
    if mind == nil then return Dialogue.learnMood(uid, mood, now) end
    if type(mood) ~= "table" then return false end
    mind.trust = clamp(mood.trust, -100, 100) or mind.trust
    mind.fear = clamp(mood.fear, -100, 100) or mind.fear
    mind.goal, mind.goalAtMs = clamp(mood.goal, -100, 100) or mind.goal, now
    return true
end

-- The drive now, settled toward 0 since it was last stirred (-100..100).
function Dialogue.goalNow(mind, now)
    if type(mind) ~= "table" then return 0 end
    local goal = tonumber(mind.goal) or 0
    local elapsed = (tonumber(now) or 0) - (tonumber(mind.goalAtMs) or tonumber(now) or 0)
    if goal == 0 or elapsed <= 0 then return goal end
    return goal * 0.5 ^ (elapsed / Dialogue.GOAL_HALF_LIFE_MS)
end

-- Sends one line to the NPC. view (optional) gets view:onReply(say, reply, outcome),
-- view:onFallback(reason, alifeSaid) and view:onDropped(). trade (optional, ALifeBrain.Trade)
-- puts the trade table in front of the NPC. options (optional): standoff = true for a parley
-- with a hostile NPC (Parley.lua; hostile NPCs are otherwise left to A-Life), opening = true
-- when the NPC speaks first (text is then a narration for the LLM, not the player's words).
-- Returns the request id, or nil and "offline" | "unsupported" | "combat" | "hostile" |
-- "busy" | a bridge reason.
function Dialogue.ask(player, record, shell, text, view, trade, options)
    options = type(options) == "table" and options or {}
    local d = deps()
    local bridge, hooks = d.bridge, d.hooks
    if Dialogue.settings.enabled ~= true or bridge == nil or not bridge:isOnline() then return nil, "offline" end
    if not Dialogue.supported(bridge) then return nil, "unsupported" end
    if record == nil or shell == nil then return nil, "gone" end
    if hooks.inCombat(record) then return nil, "combat" end
    local stance = hooks.stance(record, player)
    if stance == "hostile" and options.standoff ~= true then return nil, "hostile" end
    local uid = record.uid
    if Dialogue.pending[uid] ~= nil then
        Dialogue.metrics.busy = Dialogue.metrics.busy + 1
        return nil, "busy"
    end

    local request = hooks.dialogueContext(record, shell, player, hooks.nowMs())
    request.text = text
    request.stance = stance
    -- A careful group that lets the player close because this NPC trusts them (Rapport.lua).
    request.vouched = ALifeBrain.Rapport.vouches(record, hooks.nowMs()) or nil
    if options.standoff == true then
        request.standoff = { opening = options.opening == true, feud = options.feud == true or nil }
    end
    request.world = request.world or {}
    request.world.language = ALifeBrain.Text ~= nil and ALifeBrain.Text.language() or nil
    request.npc = request.npc or { uid = uid }
    local counts, names = hooks.inventorySummary(shell)
    request.npc.inventory = counts
    request.npc.inventoryItems = names
    request.npc.following = hooks.followingPlayer(record, player)
    request.npc.tradeable = ALifeBrain.Trade.lines(hooks.tradeableItems(shell))
    if trade ~= nil then
        -- With a trade table the NPC may ask for the player's things (they are filled in there).
        request.player = request.player or {}
        request.player.tradeable = ALifeBrain.Trade.lines(hooks.playerTradeableItems(player))
        if not trade:isEmpty() then request.trade = trade:describe() end
    end
    local id, reason = bridge:request("dialogue", request, function(ok, reply)
        Dialogue.finish(uid, player, text, ok, reply)
    end, Dialogue.settings.timeoutMs)
    if id == nil then return nil, reason end

    local now = hooks.nowMs()
    Dialogue.pending[uid] = { id = id, shell = shell, player = player, view = view, startedAtMs = now, bubbleAtMs = now,
        trade = trade, tradeVersion = trade ~= nil and trade.version or nil }
    Dialogue.metrics.asked = Dialogue.metrics.asked + 1
    hooks.hold(record, shell, player, now, Dialogue.settings.thinkHoldMs)
    hooks.say(shell, Dialogue.settings.thinkingText, player)
    return id
end

-- Talk.respond replacement (A-Life's talk box). Returns said, reason when we take over;
-- nil lets A-Life answer.
function Dialogue.handle(player, listener, text, now)
    if type(listener) ~= "table" then return nil end
    local thinking = Dialogue.settings.thinkingText
    local id, reason = Dialogue.ask(player, listener.record, listener.shell, text, nil)
    if id ~= nil then return thinking, "llm_pending" end
    if reason == "busy" then
        deps().hooks.say(listener.shell, thinking, player)
        return thinking, "llm_busy"
    end
    return nil
end

-- Called every game tick: re-shows the thinking bubble so slow replies do not look frozen.
function Dialogue.tick(now)
    local hooks = nil
    for _, entry in pairs(Dialogue.pending) do
        if now - entry.bubbleAtMs >= Dialogue.settings.thinkingRepeatMs then
            hooks = hooks or deps().hooks
            entry.bubbleAtMs = now
            hooks.say(entry.shell, Dialogue.settings.thinkingText, entry.player)
        end
    end
end

local function giveAllowed(key, now)
    local log = Dialogue.gives[key] or {}
    local recent = {}
    for _, at in ipairs(log) do
        if now - at < 3600000 then recent[#recent + 1] = at end
    end
    Dialogue.gives[key] = recent
    if #recent >= Dialogue.limits.givesPerHour then return false end
    return #recent == 0 or now - recent[#recent] >= Dialogue.limits.giveCooldownMs
end

-- Tells the sidecar what really happened, so the NPC remembers it (npc_action event).
function Dialogue.report(player, record, shell, outcome)
    local d = deps()
    if d.bridge == nil or outcome == nil then return end
    d.bridge:send("event", {
        kind = "npc_action", action = outcome.action, ok = outcome.ok, item = outcome.item,
        label = outcome.label, reason = outcome.reason, given = outcome.given, received = outcome.received,
        npc = d.hooks.describe(shell) or { uid = record.uid },
        by = { kind = "player", key = d.hooks.playerKey(player) },
    })
    -- A gift or a fair trade moves trust in the sidecar: the game learns it now, not at the next reply.
    if d.moods ~= nil and (outcome.action == "trade" or outcome.action == "give") and outcome.ok then
        d.moods.refresh(record.uid)
    end
end

-- Swaps the trade table (shared by the NPC's "accept" and the player accepting a counter-offer).
function Dialogue.executeTrade(player, record, shell, trade)
    local outcome = { action = "trade", decision = "accept", ok = false }
    if trade == nil or trade:isEmpty() then
        outcome.reason = "empty"
    else
        local ok, given, received = deps().hooks.executeTrade(record, shell, player, trade:offeredItems(), trade.asked)
        outcome.ok = ok == true
        if outcome.ok then
            outcome.given, outcome.received = given, received
            trade:clear()
        else
            outcome.reason = given or "refused"
        end
    end
    Dialogue.report(player, record, shell, outcome)
    -- In a parley, handing something over is paying the tribute.
    if ALifeBrain.Parley ~= nil then pcall(ALifeBrain.Parley.onTrade, record.uid, outcome, deps().hooks.nowMs()) end
    return outcome
end

local function stringList(value)
    local out = {}
    for _, name in ipairs(type(value) == "table" and value or {}) do
        if type(name) == "string" then out[#out + 1] = name end
    end
    return out
end

-- The NPC's answer to the trade table: accept swaps now (only if the player puts something
-- down: Hooks.executeTrade refuses "unpaid"), counter puts its own items up and names what
-- it wants back (the view fills both in; the player may accept without another round),
-- reject ends it. Without a table (A-Life's talk box) a counter is only an offer in words.
function Dialogue.actTrade(player, record, shell, reply, trade, version)
    local answer = type(reply) == "table" and type(reply.trade) == "table" and reply.trade or nil
    local decision = answer ~= nil and answer.decision or nil
    if not Dialogue.TRADE_DECISIONS[decision] then return nil end
    if decision == "counter" then
        return { action = "trade", decision = "counter", ok = true, offer = stringList(answer.npcOffer),
            wants = stringList(answer.npcWants), noTable = trade == nil or nil }
    end
    if decision == "reject" then
        local outcome = { action = "trade", decision = "reject", ok = false, reason = "rejected" }
        Dialogue.report(player, record, shell, outcome)
        return outcome
    end
    if trade ~= nil and version ~= nil and trade.version ~= version then
        -- The player changed the table while the NPC was answering; that deal is gone.
        local outcome = { action = "trade", decision = "accept", ok = false, reason = "changed" }
        Dialogue.report(player, record, shell, outcome)
        return outcome
    end
    return Dialogue.executeTrade(player, record, shell, trade)
end

-- Carries out a whitelisted intent through A-Life and reports the outcome to the sidecar,
-- so the NPC remembers what really happened. Returns the outcome table or nil.
function Dialogue.act(player, record, shell, mind, reply, now, entry)
    local intent = mind ~= nil and mind.intent or "none"
    if type(reply) == "table" and type(reply.trade) == "table" then intent = "trade" end
    if not Dialogue.ACTIONS[intent] then return nil end
    if intent == "trade" then
        return Dialogue.actTrade(player, record, shell, reply, entry and entry.trade, entry and entry.tradeVersion)
    end
    local d = deps()
    local hooks = d.hooks
    local outcome = { action = intent, ok = false }
    if intent == "give" then
        local item = type(reply) == "table" and reply.item or nil
        if not Dialogue.ITEMS[item] then return nil end
        outcome.item = item
        local key = tostring(record.uid) .. ":" .. tostring(hooks.playerKey(player))
        if not giveAllowed(key, now) then
            outcome.reason = "limit"
        else
            local ok, detail = hooks.giveItem(record, shell, player, item)
            outcome.ok = ok == true
            if outcome.ok then
                outcome.label = detail
                local log = Dialogue.gives[key]
                log[#log + 1] = now
            else
                outcome.reason = detail or "refused"
            end
        end
    elseif intent == "follow" then
        local stance = hooks.stance(record, player)
        local trusted = stance == "friendly"
            or (stance ~= "hostile" and (mind.trust or 0) >= Dialogue.limits.followTrust)
        if not trusted then
            outcome.reason = "low_trust"
        else
            outcome.ok = hooks.orderFollow(record, player, Dialogue.limits.followMs) == true
            outcome.reason = not outcome.ok and "refused" or nil
            outcome.minutes = math.floor(Dialogue.limits.followMs / 60000)
        end
    elseif intent == "stay" then
        outcome.ok = hooks.orderStay(record, shell, Dialogue.limits.stayMs) == true
        outcome.reason = not outcome.ok and "refused" or nil
    elseif intent == "leave" then
        outcome.ok = true
    end
    Dialogue.metrics.actions = Dialogue.metrics.actions + 1
    Dialogue.report(player, record, shell, outcome)
    return outcome
end

function Dialogue.finish(uid, player, text, ok, reply)
    local entry = Dialogue.pending[uid]
    Dialogue.pending[uid] = nil
    local hooks = deps().hooks
    local view = entry ~= nil and entry.view or nil
    local record = hooks.readRecord(uid)
    local shell = entry ~= nil and entry.shell or nil
    if record == nil or shell == nil or not hooks.talkable(shell, record) then
        Dialogue.metrics.dropped = Dialogue.metrics.dropped + 1
        if view ~= nil then pcall(view.onDropped, view) end
        return "dropped"
    end
    local now = hooks.nowMs()
    local say = ok and Dialogue.cleanSay(reply) or nil
    if say == nil then
        Dialogue.metrics.fallbacks = Dialogue.metrics.fallbacks + 1
        Dialogue.lastError = ok and "invalid_reply" or tostring(reply)
        local alifeSaid = hooks.respondWithAlife(player, { record = record, shell = shell }, text, now)
        if view ~= nil then pcall(view.onFallback, view, Dialogue.lastError, alifeSaid) end
        return "fallback"
    end
    hooks.say(shell, say, player)
    hooks.hold(record, shell, player, now, Dialogue.settings.replyHoldMs)
    if view == nil then hooks.quietPresence(record, player, Dialogue.settings.quietAfterMs) end
    local mind = Dialogue.remember(uid, reply, now)
    -- Enough trust and the NPC's careful group lets the player close; too little and it is wary again.
    local okRapport, rapport = pcall(ALifeBrain.Rapport.onReply, uid, now)
    rapport = okRapport and rapport or nil
    local outcome = Dialogue.act(player, record, shell, mind, reply, now, entry)
    Dialogue.metrics.answered = Dialogue.metrics.answered + 1
    -- A parley ends when the NPC opens fire (intent attack) or sends the player off (leave).
    if ALifeBrain.Parley ~= nil then pcall(ALifeBrain.Parley.onReply, uid, mind, now) end
    if view ~= nil then
        pcall(view.onReply, view, say, reply, outcome)
        if rapport ~= nil and type(view.onRapport) == "function" then pcall(view.onRapport, view, rapport) end
    elseif ALifeBrain.Text ~= nil then
        -- No window to show it in: tell the player above their head what really happened.
        local info = hooks.describe(shell) or {}
        local name = info.name or ALifeBrain.Text.get("survivor")
        local line = outcome ~= nil and ALifeBrain.Text.outcome(outcome, name) or nil
        if line ~= nil then hooks.notify(player, line, outcome.ok) end
        if rapport ~= nil then hooks.notify(player, ALifeBrain.Text.get("rapport_" .. rapport, { name = name }), rapport == "granted") end
    end
    return "answered", outcome
end

return Dialogue
