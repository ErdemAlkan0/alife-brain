-- Every touchpoint with Project A-Life lives in this file, so an A-Life update can be
-- repaired in one place. Findings behind each touchpoint: docs/alife-hooks.md
--
-- Phase 1 only reads A-Life state; nothing here patches A-Life functions yet.

ALifeBrain = ALifeBrain or {}

local Hooks = {
    ALIFE_MOD_ID = "ProjectALifeNPCs",
    TESTED_ALIFE_VERSION = "1.3.15",
}
ALifeBrain.Hooks = Hooks

-- path: dotted path under the ProjectALife global; side: where the table exists.
-- In single player every side is loaded; on a multiplayer client only shared/client.
Hooks.touchpoints = {
    { path = "ModuleRegistry.register", side = "shared" },
    { path = "ModuleRegistry.evaluate", side = "shared" },
    { path = "BehaviorProfiles.definitions", side = "shared", kind = "table" },
    { path = "Speech.say", side = "shared" },
    { path = "Speech.contextFor", side = "shared" },
    { path = "Speech.playerKey", side = "shared" },
    { path = "Speech.variable", side = "shared" },
    { path = "Talk.respond", side = "server" },
    { path = "Talk.hold", side = "server" },
    { path = "Talk.stance", side = "server" },
    { path = "Talk.observations", side = "server" },
    { path = "Talk.tolerate", side = "server" },
    { path = "Talk.writeMemory", side = "server" },
    { path = "ActorRegistry.read", side = "server" },
    { path = "DecisionLoop.states", side = "server", kind = "table" },
    { path = "DecisionLoop.setOrder", side = "server" },
    { path = "Relations.playerStance", side = "server" },
    { path = "Reputation.playerKey", side = "server" },
    { path = "TalkInput.say", side = "client" },
}

local function resolve(path)
    local value = ProjectALife
    for part in string.gmatch(path, "[^%.]+") do
        if type(value) ~= "table" then return nil end
        value = value[part]
    end
    return value
end
Hooks.resolve = resolve

local function multiplayerClient()
    return type(isClient) == "function" and isClient() == true
end

function Hooks.available()
    return type(ProjectALife) == "table"
end

-- Returns { ok = n, missing = { paths... }, skipped = n }.
function Hooks.selfCheck()
    local report = { ok = 0, missing = {}, skipped = 0 }
    for _, touchpoint in ipairs(Hooks.touchpoints) do
        if touchpoint.side == "server" and multiplayerClient() then
            report.skipped = report.skipped + 1
        else
            local value = Hooks.available() and resolve(touchpoint.path) or nil
            local expected = touchpoint.kind or "function"
            if type(value) == expected then
                report.ok = report.ok + 1
            else
                report.missing[#report.missing + 1] = touchpoint.path
            end
        end
    end
    return report
end

function Hooks.aLifeVersion()
    local version = nil
    pcall(function()
        local info = getModInfoByID(Hooks.ALIFE_MOD_ID)
        if info ~= nil then version = info:getModVersion() end
    end)
    return version
end

-- Identity --------------------------------------------------------------------

local function modDataOf(object)
    if object == nil or type(object.getModData) ~= "function" then return nil end
    local data = nil
    pcall(function()
        if type(object.hasModData) == "function" and object:hasModData() ~= true then return end
        data = object:getModData()
    end)
    return type(data) == "table" and data or nil
end

local function variableOf(object, name)
    local value = nil
    pcall(function() value = object:GetVariable(name) end)
    if value == nil or value == "" then return nil end
    return value
end

-- Living A-Life NPC body. A-Life marks bodies with modData.ProjectALifeOwned.
function Hooks.isNpc(object)
    local data = modDataOf(object)
    if data ~= nil and (data.ProjectALifeOwned == true or data.ProjectALifeActor == true) then return true end
    return object ~= nil and tostring(variableOf(object, "ALifeActor")) == "true"
end

-- A-Life NPC body that just died: Sim.markCorpse clears ProjectALifeOwned and writes
-- ProjectALifeCorpseOf = uid.
function Hooks.isNpcCorpse(object)
    local data = modDataOf(object)
    return data ~= nil and type(data.ProjectALifeCorpseOf) == "string"
end

-- Returns uid, generation (generation may be nil for corpses).
function Hooks.identity(object)
    local data = modDataOf(object)
    if data ~= nil then
        local uid = data.ProjectALifeUID
        if type(uid) ~= "string" then uid = data.ProjectALifeCorpseOf end
        if type(uid) == "string" and uid ~= "" then
            return uid, tonumber(data.ProjectALifeGeneration)
        end
    end
    if object == nil then return nil, nil end
    local uid = variableOf(object, "ALifeUID")
    if uid == nil then return nil, nil end
    return tostring(uid), tonumber(variableOf(object, "ALifeGeneration"))
end

-- Small, serializable description of an NPC for logs and prompts.
function Hooks.describe(object)
    local uid, generation = Hooks.identity(object)
    if uid == nil then return nil end
    local data = modDataOf(object) or {}
    local info = {
        uid = uid,
        generation = generation,
        factionId = data.ProjectALifeFactionId,
        profileId = data.ProjectALifeProfileId,
        activity = data.ProjectALifeActivity,
        intent = data.ProjectALifeIntent,
        behaviorState = data.ProjectALifeBehaviorState,
        behaviorIntent = data.ProjectALifeBehaviorIntent,
        wounds = tonumber(data.ProjectALifeWounds),
    }
    local registry = Hooks.available() and ProjectALife.ActorRegistry or nil
    if registry ~= nil and type(registry.read) == "function" then
        local ok, record = pcall(registry.read, uid)
        if ok and type(record) == "table" then
            local memory = type(record.memory) == "table" and record.memory or {}
            info.factionId = info.factionId or record.factionId
            info.profileId = info.profileId or record.profileId
            info.lifecycle = record.lifecycle
            info.groupId = memory.groupId
            info.outpostId = memory.outpostId
        end
    end
    return info
end

-- Same key A-Life uses for per-player memory ("sp:0" in single player, username in MP).
function Hooks.playerKey(player)
    if player == nil then return nil end
    local speech = Hooks.available() and ProjectALife.Speech or nil
    if speech ~= nil and type(speech.playerKey) == "function" then
        local ok, key = pcall(speech.playerKey, player)
        if ok and key ~= nil then return tostring(key) end
    end
    local key = nil
    pcall(function()
        if instanceof(player, "IsoPlayer") then
            if type(isClient) == "function" and isClient() then
                key = player:getUsername()
            else
                key = "sp:" .. tostring(player:getPlayerNum())
            end
        end
    end)
    return key
end

-- Debug helper: spawns A-Life NPCs a few tiles east of the player through A-Life's own
-- debug spawner (server/.../Admin/ALifeDebugService.lua). A-Life only accepts
-- debugSpawnCatalog while its diagnostics are on, so this switches them on first.
-- Works in single player and for admins.
function Hooks.spawnTestNpc(player, encounterId, count, distance)
    if player == nil or type(sendClientCommand) ~= "function" then return false, "no_player" end
    local x, y, z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    sendClientCommand(player, "ProjectALife", "alifeDiagnostics", { enabled = true, recorder = false })
    sendClientCommand(player, "ProjectALife", "debugSpawnCatalog", {
        encounterId = encounterId or "patrol",
        count = tonumber(count) or 1,
        x = x + (tonumber(distance) or 6), y = y, z = z,
    })
    return true
end

function Hooks.isPlayer(object)
    local ok, result = pcall(function() return instanceof(object, "IsoPlayer") end)
    return ok and result == true
end

return Hooks
