-- In-game forward pass of the policy networks trained in rl/ (behavior cloning now, PPO
-- later). Weights come from PolicyWeights.lua, which rl/alifebrain_rl/bc.py writes:
--   { schema, created, nets = { decision = net, response = net } }
--   net = { actions = { "default", "regroup", ... }, mean = {...}, std = {...},
--           layers = { { w = { row per output }, b = {...}, act = "tanh" | "linear" }, ... },
--           check = { input = {...}, logits = {...} }, metrics = {...} }
-- An action is an A-Life module id of that chain, or "default" (A-Life's own fallback).

require "ALifeBrain/Features"

ALifeBrain = ALifeBrain or {}

local Policy = { CHECK_TOLERANCE = 1e-3 }
ALifeBrain.Policy = Policy

local function tanh(x)
    if x > 20 then return 1 end
    if x < -20 then return -1 end
    local e = math.exp(2 * x)
    return (e - 1) / (e + 1)
end

-- Raw scores, one per net.actions entry.
function Policy.logits(net, vector)
    local x = {}
    for index = 1, #net.mean do
        local std = net.std[index]
        if std == nil or std == 0 then std = 1 end
        x[index] = ((vector[index] or 0) - net.mean[index]) / std
    end
    for _, layer in ipairs(net.layers) do
        local y = {}
        local tanhLayer = layer.act == "tanh"
        for j = 1, #layer.b do
            local row, sum = layer.w[j], layer.b[j]
            for i = 1, #row do sum = sum + row[i] * x[i] end
            y[j] = tanhLayer and tanh(sum) or sum
        end
        x = y
    end
    return x
end

-- The best action this NPC may take: one of allowed (module ids) or "default".
function Policy.choose(net, vector, allowed)
    local permitted = { default = true }
    for _, id in ipairs(allowed or {}) do permitted[id] = true end
    local scores = Policy.logits(net, vector)
    local best, bestScore = "default", nil
    for index, action in ipairs(net.actions) do
        if permitted[action] and (bestScore == nil or scores[index] > bestScore) then
            best, bestScore = action, scores[index]
        end
    end
    return best
end

-- The exporter stores one input and the logits it computed; matching them proves this
-- forward pass and the trainer agree. Returns true, or false and a reason.
function Policy.check(net)
    if type(net) ~= "table" or type(net.actions) ~= "table" or type(net.layers) ~= "table" then return false, "malformed" end
    if type(net.mean) ~= "table" or #net.mean ~= #ALifeBrain.Features.NAMES then return false, "feature_count" end
    local check = net.check
    if type(check) ~= "table" or type(check.input) ~= "table" or type(check.logits) ~= "table" then return true end
    local scores = Policy.logits(net, check.input)
    for index, expected in ipairs(check.logits) do
        if scores[index] == nil or math.abs(scores[index] - expected) > Policy.CHECK_TOLERANCE then
            return false, "check_mismatch"
        end
    end
    return true
end

-- Usable nets from a weights table: { decision = net, ... }, plus a note per rejected one.
function Policy.load(weights)
    if type(weights) ~= "table" or type(weights.nets) ~= "table" then return nil, { "no_weights" } end
    if weights.schema ~= ALifeBrain.Features.SCHEMA then
        return nil, { "schema " .. tostring(weights.schema) .. " (game uses " .. tostring(ALifeBrain.Features.SCHEMA) .. ")" }
    end
    local nets, notes, loaded = {}, {}, 0
    for kind, net in pairs(weights.nets) do
        local ok, reason = Policy.check(net)
        if ok then
            nets[kind] = net
            loaded = loaded + 1
        else
            notes[#notes + 1] = tostring(kind) .. ": " .. tostring(reason)
        end
    end
    -- (Kahlua has no next(); counted instead.)
    if loaded == 0 then return nil, notes end
    return nets, notes
end

return Policy
