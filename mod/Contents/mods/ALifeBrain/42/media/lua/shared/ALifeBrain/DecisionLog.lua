-- Behavior cloning data: samples A-Life's own decisions (Hooks.installDecisionTap) with what
-- the NPC saw (Features.vector) and which modules it was allowed to run, and sends them to
-- the sidecar in batches ("decision_samples" events, docs/bridge-protocol.md). The sidecar
-- writes the dataset that rl/ trains on.
--
-- With trained weights (PolicyWeights.lua) the policy also runs in shadow mode: it picks
-- an action for every sampled decision and we count how often it agrees with A-Life. It
-- never acts; A-Life stays in charge.

require "ALifeBrain/Json"
require "ALifeBrain/Features"
require "ALifeBrain/Policy"

ALifeBrain = ALifeBrain or {}

local Json, Features, Policy = ALifeBrain.Json, ALifeBrain.Features, ALifeBrain.Policy

local DecisionLog = {
    settings = {
        enabled = true,
        samplePeriodMs = 3000, -- same NPC, same chain, same choice: at most one sample per period
        maxPerSecond = 20,
        batchRows = 12, -- keeps an event line well under the bridge's 16000 characters
        flushMs = 5000,
        maxQueue = 240,
        forgetMs = 600000,
        digits = 3,
    },
    last = {},
    queue = {},
    window = { atMs = 0, count = 0 },
    lastFlushMs = 0,
    sentNames = false,
    nets = nil,
    stats = nil,
}
ALifeBrain.DecisionLog = DecisionLog

-- Tests replace this with fakes: { bridge = ..., hooks = ... }.
DecisionLog.override = nil

local function deps()
    if DecisionLog.override ~= nil then return DecisionLog.override end
    return { bridge = ALifeBrain.bridge, hooks = ALifeBrain.Hooks }
end

function DecisionLog.reset()
    DecisionLog.last, DecisionLog.queue = {}, {}
    DecisionLog.window = { atMs = 0, count = 0 }
    DecisionLog.lastFlushMs, DecisionLog.sentNames = 0, false
    DecisionLog.stats = { seen = 0, sampled = 0, sent = 0, dropped = 0, failed = 0, labels = {},
        shadow = { decision = { n = 0, agree = 0 }, response = { n = 0, agree = 0 } } }
end
DecisionLog.reset()

-- Samples only go out while the sidecar is up and stores them.
function DecisionLog.collecting(bridge)
    return DecisionLog.settings.enabled == true and bridge ~= nil and bridge:isOnline()
        and type(bridge.features) == "table" and bridge.features.dataset == true
end

-- Loads trained nets for shadow mode. Returns the loaded chain names and notes.
function DecisionLog.loadPolicy(weights)
    if weights == nil then
        pcall(require, "ALifeBrain/PolicyWeights")
        weights = ALifeBrain.PolicyWeights
    end
    if weights == nil then
        DecisionLog.nets = nil
        return {}, {} -- the placeholder file: nothing trained yet
    end
    local nets, notes = Policy.load(weights)
    DecisionLog.nets = nets
    local loaded = {}
    for kind in pairs(nets or {}) do loaded[#loaded + 1] = kind end
    table.sort(loaded)
    return loaded, notes
end

-- Hooks.installDecisionTap callback. moduleId is nil when A-Life fell back to its own logic.
function DecisionLog.onDecision(kind, actor, shell, context, moduleId)
    local stats, settings = DecisionLog.stats, DecisionLog.settings
    stats.seen = stats.seen + 1
    if type(actor) ~= "table" or type(actor.uid) ~= "string" then return end
    local d = deps()
    local net = DecisionLog.nets ~= nil and DecisionLog.nets[kind] or nil
    local collect = DecisionLog.collecting(d.bridge)
    if not collect and net == nil then return end

    local now = d.hooks.nowMs()
    local label = type(moduleId) == "string" and moduleId or "default"
    local byUid = DecisionLog.last[kind]
    if byUid == nil then
        byUid = {}
        DecisionLog.last[kind] = byUid
    end
    local last = byUid[actor.uid]
    if last ~= nil and last.label == label and now - last.atMs < settings.samplePeriodMs then return end
    local window = DecisionLog.window
    if now - window.atMs >= 1000 then window.atMs, window.count = now, 0 end
    if window.count >= settings.maxPerSecond then
        stats.dropped = stats.dropped + 1
        return
    end
    window.count = window.count + 1
    byUid[actor.uid] = { label = label, atMs = now }

    local vector = Features.vector(d.hooks.decisionObservation(kind, actor, shell, context, now))
    local allowed = d.hooks.allowedModules(kind, actor)
    local row = { d = kind, a = label, o = Features.rounded(vector, settings.digits), m = allowed, u = actor.uid,
        f = actor.factionId, p = actor.profileId, t = now }
    if net ~= nil then
        local choice = Policy.choose(net, vector, allowed)
        row.pa = choice
        local shadow = stats.shadow[kind]
        shadow.n = shadow.n + 1
        if choice == label then shadow.agree = shadow.agree + 1 end
    end
    stats.sampled = stats.sampled + 1
    local labelKey = kind .. ":" .. label
    stats.labels[labelKey] = (stats.labels[labelKey] or 0) + 1
    if collect then
        if #DecisionLog.queue >= settings.maxQueue then
            table.remove(DecisionLog.queue, 1)
            stats.dropped = stats.dropped + 1
        end
        DecisionLog.queue[#DecisionLog.queue + 1] = row
    end
end

local function forgetOld(now)
    for _, byUid in pairs(DecisionLog.last) do
        for uid, entry in pairs(byUid) do
            if now - entry.atMs > DecisionLog.settings.forgetMs then byUid[uid] = nil end
        end
    end
end

-- Called every game tick: sends a batch when it is full or old enough.
function DecisionLog.tick(now)
    local settings, bridge = DecisionLog.settings, deps().bridge
    if not DecisionLog.collecting(bridge) then
        -- Offline: drop what is queued, and send the feature names again once back.
        if #DecisionLog.queue > 0 then DecisionLog.queue = {} end
        DecisionLog.sentNames = false
        return
    end
    if #DecisionLog.queue == 0 then return end
    if #DecisionLog.queue < settings.batchRows and now - DecisionLog.lastFlushMs < settings.flushMs then return end
    DecisionLog.lastFlushMs = now
    local rows = Json.array({})
    while #rows < settings.batchRows and #DecisionLog.queue > 0 do rows[#rows + 1] = table.remove(DecisionLog.queue, 1) end
    local data = { kind = "decision_samples", schema = Features.SCHEMA, rows = rows }
    if not DecisionLog.sentNames then data.names = Features.NAMES end
    local ok, reason = bridge:send("event", data)
    if ok then
        DecisionLog.stats.sent = DecisionLog.stats.sent + #rows
        DecisionLog.sentNames = true
    else
        DecisionLog.stats.failed = DecisionLog.stats.failed + 1
        DecisionLog.lastError = tostring(reason)
    end
    forgetOld(now)
end

-- Shadow mode agreement per chain: { decision = { n, agree, rate }, ... }.
function DecisionLog.agreement()
    local out = {}
    for kind, shadow in pairs(DecisionLog.stats.shadow) do
        out[kind] = { n = shadow.n, agree = shadow.agree, rate = shadow.n > 0 and shadow.agree / shadow.n or nil }
    end
    return out
end

return DecisionLog
