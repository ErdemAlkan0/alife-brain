-- The observation vector of the RL policy. The game builds it here, the same way, when it
-- logs A-Life's decisions (behavior cloning data, DecisionLog.lua) and when it asks the
-- policy (Policy.lua), so training and play always agree. Raw values come from
-- Hooks.decisionObservation. Changing, adding or reordering a feature means a new SCHEMA
-- number (the sidecar keeps one dataset per schema) and retraining.

ALifeBrain = ALifeBrain or {}

local Features = { SCHEMA = 1 }
ALifeBrain.Features = Features

Features.NAMES = {
    "health", "wounds", "bleeding", "downed", "endurance",
    "firearm", "melee", "rounds", "jammed",
    "threat", "threat_player", "threat_zombie", "threat_actor", "threat_distance",
    "zombies_near", "zombies_around", "squad_near", "others_near",
    "player_distance", "player_armed", "player_aiming",
    "stance_hostile", "stance_careful", "stance_neutral", "stance_friendly",
    "hour_sin", "hour_cos", "night",
    "order_follow", "order_hold", "order_patrol",
    "afraid",
    "was_idle", "was_movement", "was_combat", "was_retreat", "was_recovering", "was_scavenging",
    "trust", "fear", "goal",
    "robbery", "talk_hold",
}

local STANCES = { "hostile", "careful", "neutral", "friendly" }
local ORDERS = { "follow", "hold", "patrol" }
local STATES = { "idle", "movement", "combat", "retreat", "recovering", "scavenging" }

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

-- value / scale in 0..1; missing counts as 0.
local function ratio(value, scale)
    value = tonumber(value)
    if value == nil then return 0 end
    return clamp(value / scale, 0, 1)
end

local function flag(value) return value == true and 1 or 0 end

-- raw: plain values (all optional) -> list of #Features.NAMES numbers, each in 0..1 or -1..1.
function Features.vector(raw)
    raw = type(raw) == "table" and raw or {}
    local out = {}
    local function put(value) out[#out + 1] = value end

    local maxHealth = tonumber(raw.maxHealth) or 1
    if maxHealth <= 0 then maxHealth = 1 end
    put(clamp((tonumber(raw.health) or maxHealth) / maxHealth, 0, 1))
    put(ratio(raw.wounds, 5))
    put(flag(raw.bleeding))
    put(flag(raw.downed))
    local enduranceMax = tonumber(raw.enduranceMax) or 0
    put(enduranceMax > 0 and clamp((tonumber(raw.endurance) or enduranceMax) / enduranceMax, 0, 1) or 1)

    local weapon = raw.weaponClass
    put((weapon == "handgun" or weapon == "rifle") and 1 or 0)
    put((weapon == "melee" or weapon == "spear") and 1 or 0)
    put(ratio(raw.rounds, 30))
    put(flag(raw.jammed))

    local threat = raw.threat == true
    local kind = threat and raw.threatKind or nil
    put(flag(threat))
    put(kind == "player" and 1 or 0)
    put(kind == "zombie" and 1 or 0)
    put(kind == "actor" and 1 or 0)
    put((threat and raw.threatDistance ~= nil) and ratio(raw.threatDistance, 30) or 1)

    put(ratio(raw.zombiesNear, 10))
    put(ratio(raw.zombiesAround, 25))
    put(ratio(raw.squadNear, 6))
    put(ratio(raw.othersNear, 6))

    put(raw.playerDistance ~= nil and ratio(raw.playerDistance, 50) or 1)
    put(flag(raw.playerArmed))
    put(flag(raw.playerAiming))
    for _, stance in ipairs(STANCES) do put(raw.stance == stance and 1 or 0) end

    local hour = tonumber(raw.hour)
    if hour ~= nil then
        local angle = hour / 24 * 2 * math.pi
        put(math.sin(angle))
        put(math.cos(angle))
        put((hour < 6 or hour >= 21) and 1 or 0)
    else
        put(0); put(0); put(0)
    end

    for _, order in ipairs(ORDERS) do put(raw.order == order and 1 or 0) end
    put(flag(raw.afraid))
    for _, state in ipairs(STATES) do put(raw.previous == state and 1 or 0) end

    -- LLM moods toward the player (-100..100) and the goal knob (-1..1, phase 5).
    put(clamp((tonumber(raw.trust) or 0) / 100, -1, 1))
    put(clamp((tonumber(raw.fear) or 0) / 100, -1, 1))
    put(clamp(tonumber(raw.goal) or 0, -1, 1))

    put(flag(raw.robbery))
    put(flag(raw.talkHold))
    return out
end

-- Rounded copy for the wire (digits after the point); keeps dataset lines short.
function Features.rounded(vector, digits)
    local scale = 10 ^ (digits or 3)
    local out = {}
    for index, value in ipairs(vector) do out[index] = math.floor(value * scale + 0.5) / scale end
    return out
end

return Features
