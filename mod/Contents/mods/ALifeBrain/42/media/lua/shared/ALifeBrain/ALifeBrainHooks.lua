-- Every touchpoint with Project A-Life lives in this file, so an A-Life update can be
-- repaired in one place. Findings behind each touchpoint: docs/alife-hooks.md
--
-- Wrapped A-Life functions (originals kept, every wrapper falls back to them):
-- Talk.respond (LLM dialogue), TalkInput.open (chat window) and ModuleRegistry.evaluate
-- (watches decisions for behavior cloning; never changes them), Stealth.stanceActive
-- (followers sneak with the player). Registered through A-Life's own module API: three
-- response modules (Hooks.MODULES: parley, standoff, companion).

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
    { path = "ModuleRegistry.allows", side = "shared" },
    { path = "ModuleRegistry.order", side = "shared", kind = "table" },
    { path = "ActorRegistry.peek", side = "server" },
    { path = "ActorRegistry.each", side = "server" },
    { path = "DecisionLoop.followTarget", side = "server" },
    { path = "DecisionLoop.refreshDirective", side = "server" },
    { path = "Stealth.stanceActive", side = "server" },
    { path = "Survival.healthRatio", side = "server" },
    { path = "Survival.retreatTarget", side = "server" },
    { path = "Perception.retaliationTarget", side = "server" },
    { path = "Perception.ignore", side = "server" },
    { path = "Reputation.recordedStatus", side = "server" },
    { path = "Voice.play", side = "server" },
    { path = "AIFence.faceAimPoint", side = "shared" },
    { path = "Animations.apply", side = "shared" },
    { path = "BehaviorProfiles.definitions", side = "shared", kind = "table" },
    { path = "Speech.say", side = "shared" },
    { path = "Speech.contextFor", side = "shared" },
    { path = "Speech.playerKey", side = "shared" },
    { path = "Speech.variable", side = "shared" },
    { path = "Speech.talkable", side = "shared" },
    { path = "Speech.nearestTown", side = "shared" },
    { path = "DialogueRoles.describe", side = "shared" },
    { path = "Catalog.npc", side = "shared" },
    { path = "Catalog.faction", side = "shared" },
    { path = "Talk.respond", side = "server" },
    { path = "Talk.inCombat", side = "server" },
    { path = "Talk.lineOfSight", side = "server" },
    { path = "TalkSupplies.matches", side = "server" },
    { path = "ModuleTalkPresence.partyKey", side = "server" },
    { path = "ModuleTalkPresence.greeted", side = "server", kind = "table" },
    { path = "ModuleTalkPresence.stared", side = "server", kind = "table" },
    { path = "DecisionLoop.orders", side = "server", kind = "table" },
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
    { path = "TalkInput.open", side = "client" },
    { path = "Persistence.squadCap", side = "server", kind = "number" },
    { path = "ModuleRobbery.active", side = "server", kind = "table" },
    { path = "Telemetry.events", side = "server", kind = "table" },
    { path = "Telemetry.counters", side = "server", kind = "table" },
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

local function xyzOf(object)
    local x, y, z = nil, nil, nil
    pcall(function() x, y, z = object:getX(), object:getY(), object:getZ() end)
    return x, y, z
end

local function flatDistance(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
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
    local catalog = Hooks.available() and ProjectALife.Catalog or nil
    if catalog ~= nil then
        pcall(function()
            local profile = catalog.npc(info.profileId)
            if type(profile) == "table" and type(profile.general) == "table" then info.name = profile.general.name end
        end)
        pcall(function()
            local faction = catalog.faction(info.factionId)
            if type(faction) == "table" and type(faction.general) == "table" then info.factionName = faction.general.name end
        end)
    end
    return info
end

-- Dialogue -------------------------------------------------------------------
-- Talk.respond(player, listener, text, now, choiceIntent) is A-Life's free-text answer
-- (server/.../Talk/ALifeTalk.lua). listener = { record, shell, distance, inCone }.

local function talk() return Hooks.available() and ProjectALife.Talk or nil end
local function speech() return Hooks.available() and ProjectALife.Speech or nil end

function Hooks.nowMs()
    if type(getTimestampMs) == "function" then return getTimestampMs() end
    return math.floor(os.time() * 1000)
end

-- The save this game runs ("<game mode>/<save name>", the way the game's own save list names
-- it), or nil.
function Hooks.worldKey()
    local key = nil
    pcall(function()
        local world = getWorld()
        if world ~= nil then key = tostring(world:getGameMode()) .. "/" .. tostring(world:getWorld()) end
    end)
    return key
end

-- handler(player, listener, text, now) returns said, reason to answer instead of A-Life,
-- or nil to let A-Life answer. Menu choices (choiceIntent ~= nil) always go to A-Life.
function Hooks.installTalkHook(handler)
    local current = talk()
    if current == nil or type(current.respond) ~= "function" then return false, "talk_unavailable" end
    Hooks.talkHandler = handler
    if Hooks.originalRespond ~= nil then return true, "already_installed" end
    local original = current.respond
    Hooks.originalRespond = original
    current.respond = function(player, listener, text, now, choiceIntent)
        if choiceIntent == nil and type(Hooks.talkHandler) == "function" then
            local ok, said, reason = pcall(Hooks.talkHandler, player, listener, text, now)
            if ok and said ~= nil then return said, reason end
            if not ok then print("[ALifeBrain] dialogue handler failed: " .. tostring(said)) end
        end
        return original(player, listener, text, now, choiceIntent)
    end
    return true, "installed"
end

-- A-Life's own answer (canned lines), used when the LLM path fails.
function Hooks.respondWithAlife(player, listener, text, now)
    local respond = Hooks.originalRespond or (talk() and talk().respond)
    if type(respond) ~= "function" then return nil end
    local ok, said, reason = pcall(respond, player, listener, text, now or Hooks.nowMs(), nil)
    if ok then return said, reason end
    return nil
end

function Hooks.inCombat(record)
    local current = talk()
    if current == nil or type(current.inCombat) ~= "function" then return false end
    local ok, busy = pcall(current.inCombat, record)
    return ok and busy == true
end

-- "hostile" | "careful" | "neutral" | "friendly"
function Hooks.stance(record, player)
    local current = talk()
    if current == nil or type(current.stance) ~= "function" then return "neutral" end
    local ok, stance = pcall(current.stance, record, player)
    return ok and type(stance) == "string" and stance or "neutral"
end

-- Keeps the NPC still and facing the player (A-Life's conversation hold).
function Hooks.hold(record, shell, player, now, ms)
    local current = talk()
    if current == nil or type(current.hold) ~= "function" then return false end
    return pcall(current.hold, record, shell, player, now or Hooks.nowMs(), ms)
end

function Hooks.say(shell, text, player)
    local current = speech()
    if current == nil or type(current.say) ~= "function" then return false end
    local ok, said = pcall(current.say, shell, text, { face = player })
    return ok and said == true
end

function Hooks.readRecord(uid)
    local registry = Hooks.available() and ProjectALife.ActorRegistry or nil
    if registry == nil or type(registry.read) ~= "function" then return nil end
    local ok, record = pcall(registry.read, uid)
    return ok and type(record) == "table" and record or nil
end

function Hooks.talkable(shell, record)
    local current = speech()
    if current == nil or type(current.talkable) ~= "function" then return false end
    local ok, able = pcall(current.talkable, shell, record, Hooks.nowMs())
    return ok and able == true
end

-- Everything the sidecar needs to voice this NPC (sent as the "dialogue" request).
function Hooks.dialogueContext(record, shell, player, now)
    local npc = Hooks.describe(shell) or { uid = record.uid }
    local context = {}
    pcall(function() context = speech().contextFor(record, player) or {} end)
    npc.role, npc.register, npc.temperament, npc.sex = context.role, context.register, context.temperament, context.sex
    pcall(function() npc.roleLabel = ProjectALife.DialogueRoles.describe(record, context.day).label end)
    local facts = {}
    pcall(function() facts = talk().observations(record, shell, player, now) or {} end)
    local weapon, town = nil, nil
    pcall(function()
        local item = player:getPrimaryHandItem()
        if item ~= nil then weapon = string.lower(tostring(item:getDisplayName())) end
    end)
    pcall(function() town = speech().nearestTown(shell:getX(), shell:getY()) end)
    return {
        npc = npc,
        facts = facts,
        player = { key = Hooks.playerKey(player), weapon = weapon },
        world = { town = town, hour = context.hour, day = context.day },
    }
end

-- Conversation session ---------------------------------------------------------

-- Ends our conversation hold early (what Talk.session does when A-Life's menu closes).
function Hooks.release(record, player)
    local current = talk()
    if current == nil or type(current.writeMemory) ~= "function" then return false end
    local key = Hooks.playerKey(player)
    return pcall(current.writeMemory, record.uid, function(memory)
        if memory.talkHoldPlayerKey == key then
            memory.talkHoldUntilMs = nil
            memory.talkHoldPlayerKey = nil
        end
    end)
end

-- Stops ModuleTalkPresence from greeting or "staring at" the player for a while after a
-- conversation (server/.../Behaviours/ALifeModuleTalkPresence.lua keys both by party).
function Hooks.quietPresence(record, player, ms)
    local presence = Hooks.available() and ProjectALife.ModuleTalkPresence or nil
    if presence == nil or type(presence.partyKey) ~= "function" then return false end
    return pcall(function()
        local party = presence.partyKey(record, Hooks.playerKey(player))
        local untilMs = Hooks.nowMs() + ms
        presence.greeted[party] = math.max(tonumber(presence.greeted[party]) or 0, untilMs)
        presence.stared[party] = math.max(tonumber(presence.stared[party]) or 0, untilMs)
    end)
end

function Hooks.withinReach(player, shell, tiles)
    local ok, close = pcall(function()
        if math.floor(shell:getZ()) ~= math.floor(player:getZ()) then return false end
        local dx, dy = shell:getX() - player:getX(), shell:getY() - player:getY()
        return dx * dx + dy * dy <= tiles * tiles
    end)
    return ok and close == true
end

function Hooks.lineOfSight(player, shell)
    local current = talk()
    if current == nil or type(current.lineOfSight) ~= "function" then return true end
    local ok, clear = pcall(current.lineOfSight, player, shell)
    return not ok or clear == true
end

-- Talkable A-Life NPCs near the player, nearest first: { uid, shell, record, name, factionName, distance }.
function Hooks.nearbyNpcs(player, tiles)
    local found = {}
    pcall(function()
        local zombies = getCell():getZombieList()
        for index = 0, zombies:size() - 1 do
            local shell = zombies:get(index)
            if shell ~= nil and Hooks.isNpc(shell) and Hooks.withinReach(player, shell, tiles) then
                local uid = Hooks.identity(shell)
                local record = uid ~= nil and Hooks.readRecord(uid) or nil
                if record ~= nil and Hooks.talkable(shell, record) then
                    local info = Hooks.describe(shell) or {}
                    local dx, dy = shell:getX() - player:getX(), shell:getY() - player:getY()
                    found[#found + 1] = { uid = uid, shell = shell, record = record, name = info.name,
                        factionName = info.factionName, distance = math.sqrt(dx * dx + dy * dy) }
                end
            end
        end
    end)
    table.sort(found, function(a, b) return a.distance < b.distance end)
    return found
end

-- Items -------------------------------------------------------------------------
-- A-Life's own supply rules (server/.../Talk/ALifeTalkSupplies.lua): drinkable water,
-- safe food, first-aid items, never equipped items.

Hooks.SUPPLY_INTENTS = { water = "ASK_WATER", food = "ASK_FOOD", medicine = "ASK_MEDS" }

local function supplies() return Hooks.available() and ProjectALife.TalkSupplies or nil end

local function matches(rules, item, name)
    local ok, yes = pcall(rules.matches, item, Hooks.SUPPLY_INTENTS[name])
    return ok and yes == true
end

-- Direct moves (like A-Life's own TalkSupplies) skip the transfer actions that normally
-- redraw the inventory; mark both sides dirty so vanilla and Inventory Tetris refresh now.
local function touched(...)
    for _, container in ipairs({ ... }) do
        pcall(function() container:setDrawDirty(true) end)
    end
    if ISInventoryPage ~= nil and type(ISInventoryPage.dirtyUI) == "function" then pcall(ISInventoryPage.dirtyUI) end
end

-- Spare items the NPC could hand over: counts { water = n, food = n, medicine = n } and
-- display names { medicine = { "Bandage", ... } } (at most 5 per kind) so the LLM names
-- the real thing.
function Hooks.inventorySummary(shell)
    local rules = supplies()
    local counts = { water = 0, food = 0, medicine = 0 }
    local names = { water = {}, food = {}, medicine = {} }
    if rules == nil or type(rules.matches) ~= "function" then return counts, names end
    pcall(function()
        local items = shell:getInventory():getItems()
        for index = 0, math.min(items:size(), 256) - 1 do
            local item = items:get(index)
            for name in pairs(counts) do
                if matches(rules, item, name) then
                    counts[name] = counts[name] + 1
                    if #names[name] < 5 then
                        local ok, label = pcall(function() return tostring(item:getDisplayName()) end)
                        if ok then names[name][#names[name] + 1] = label end
                    end
                end
            end
        end
    end)
    return counts, names
end

-- Short on-screen note above the player (used when no chat window shows the outcome).
function Hooks.notify(player, text, good)
    if player == nil or type(text) ~= "string" then return false end
    return pcall(function()
        if good == false then player:setHaloNote(text, 255, 170, 90, 400) else player:setHaloNote(text, 130, 230, 130, 400) end
    end)
end

-- A-Life's single-player talk box opens through TalkInput.open (client/.../Talk/ALifeTalkInput.lua,
-- bound to the "Toggle chat" key). opener() returns true when it opened something else instead.
function Hooks.wrapTalkInput(opener)
    local input = Hooks.available() and ProjectALife.TalkInput or nil
    if input == nil or type(input.open) ~= "function" then return false, "talk_input_unavailable" end
    Hooks.talkInputOpener = opener
    if Hooks.originalTalkInputOpen ~= nil then return true, "already_installed" end
    local original = input.open
    Hooks.originalTalkInputOpen = original
    input.open = function(...)
        if type(Hooks.talkInputOpener) == "function" then
            local ok, opened = pcall(Hooks.talkInputOpener)
            if ok and opened == true then return end
            if not ok then print("[ALifeBrain] chat window opener failed: " .. tostring(opened)) end
        end
        return original(...)
    end
    return true, "installed"
end

-- Moves one matching item from the NPC to the player, the way TalkSupplies.respond does.
-- Returns true, displayName or false, reason ("no_item" | "too_far" | "refused").
function Hooks.giveItem(record, shell, player, name)
    local rules = supplies()
    if Hooks.SUPPLY_INTENTS[name] == nil or rules == nil or type(rules.matches) ~= "function" then
        return false, "refused"
    end
    -- In a fight: "combat" (play test, 2026-10-11: a gift handed over mid-fight read as "could not do it").
    if Hooks.inCombat(record) then return false, "combat" end
    if Hooks.stance(record, player) == "hostile" then return false, "refused" end
    if not Hooks.withinReach(player, shell, 6) or not Hooks.lineOfSight(player, shell) then return false, "too_far" end
    local result, detail = false, "refused"
    pcall(function()
        local source, destination = shell:getInventory(), player:getInventory()
        local chosen = nil
        local items = source:getItems()
        for index = 0, math.min(items:size(), 256) - 1 do
            local item = items:get(index)
            if matches(rules, item, name) then chosen = item; break end
        end
        if chosen == nil then result, detail = false, "no_item"; return end
        local label = tostring(chosen:getDisplayName())
        source:Remove(chosen)
        local added, received = pcall(function() return destination:AddItem(chosen) end)
        if not added or received == nil then
            source:AddItem(chosen)
            return
        end
        if type(isServer) == "function" and isServer() then
            sendRemoveItemFromContainer(source, chosen)
            sendAddItemToContainer(destination, chosen)
        end
        touched(source, destination)
        result, detail = true, label
    end)
    return result, detail
end

-- Trading --------------------------------------------------------------------------

function Hooks.itemInfo(item)
    local info = nil
    pcall(function()
        info = { id = item:getID(), type = tostring(item:getFullType()), name = tostring(item:getDisplayName()),
            tex = item:getTex() }
    end)
    return info
end

local function busyItem(owner, item)
    local busy = false
    pcall(function()
        if item == owner:getPrimaryHandItem() or item == owner:getSecondaryHandItem() then busy = true end
    end)
    if busy then return true end
    pcall(function() if owner:isEquipped(item) then busy = true end end)
    pcall(function() if item:isEquipped() then busy = true end end)
    pcall(function() if owner:getWornItems():contains(item) then busy = true end end)
    pcall(function() if item:getAttachedSlot() ~= nil and item:getAttachedSlot() > -1 then busy = true end end)
    pcall(function() if instanceof(item, "Key") or instanceof(item, "KeyRing") then busy = true end end)
    return busy
end

-- A bag with things in it would carry them along unseen, so only empty ones are traded.
local function holdsItems(item)
    local full = false
    pcall(function()
        if item:IsInventoryContainer() and item:getInventory():getItems():size() > 0 then full = true end
    end)
    return full
end

-- Groups items by type into { { type, name, count, items, tex } }; false once limit types are full.
local function addToGroups(groups, byType, item, limit)
    local info = Hooks.itemInfo(item)
    if info == nil then return true end
    local group = byType[info.type]
    if group == nil then
        if #groups >= limit then return false end
        group = { type = info.type, name = info.name, count = 0, items = {}, tex = info.tex }
        byType[info.type] = group
        groups[#groups + 1] = group
    end
    group.count = group.count + 1
    group.items[#group.items + 1] = item
    return true
end

-- What an NPC could trade away, grouped by item type: { { type, name, count, items, tex } }.
-- Hand items, worn and attached items (its loadout), keys and bags with things in them are
-- never offered.
function Hooks.tradeableItems(shell, limit)
    local groups, byType = {}, {}
    pcall(function()
        local items = shell:getInventory():getItems()
        for index = 0, math.min(items:size(), 256) - 1 do
            local item = items:get(index)
            if not busyItem(shell, item) and not holdsItems(item) then
                if not addToGroups(groups, byType, item, limit or 30) then return end
            end
        end
    end)
    return groups
end

-- Why the player cannot put an item of their own on the table, or nil.
local function playerBlock(player, item)
    if busyItem(player, item) then return "equipped" end
    local favorite = false
    pcall(function() favorite = item:isFavorite() == true end)
    if favorite then return "favorite" end
    if holdsItems(item) then return "not_empty" end
    return nil
end

-- true, or false and "not_yours" | "equipped" | "favorite" | "not_empty".
function Hooks.playerCanTrade(player, item)
    local mine = false
    pcall(function() mine = player:getInventory():containsRecursive(item) == true end)
    if not mine then return false, "not_yours" end
    local reason = playerBlock(player, item)
    if reason ~= nil then return false, reason end
    return true
end

-- The player's own tradeable things (main inventory and the bags in it), grouped like
-- tradeableItems: the NPC may ask for these, and its asks are filled in from them.
function Hooks.playerTradeableItems(player, limit)
    local groups, byType = {}, {}
    pcall(function()
        local function scan(container, depth)
            local items = container:getItems()
            for index = 0, math.min(items:size(), 256) - 1 do
                local item = items:get(index)
                if playerBlock(player, item) == nil and not addToGroups(groups, byType, item, limit or 30) then
                    return false
                end
                if depth == 0 and item:IsInventoryContainer() and not scan(item:getInventory(), 1) then return false end
            end
            return true
        end
        scan(player:getInventory(), 0)
    end)
    return groups
end

local function move(item, destination)
    local source = item:getContainer()
    if source == nil then return false end
    source:Remove(item)
    local added, received = pcall(function() return destination:AddItem(item) end)
    if not added or received == nil then
        source:AddItem(item)
        return false
    end
    if type(isServer) == "function" and isServer() then
        sendRemoveItemFromContainer(source, item)
        sendAddItemToContainer(destination, item)
    end
    touched(source, destination)
    return true
end

-- Moves every item, noting where each came from; false at the first one that will not move.
local function moveAll(items, destination, journal)
    for _, item in ipairs(items) do
        local source = item:getContainer()
        if not move(item, destination) then return false end
        journal[#journal + 1] = { item = item, source = source }
    end
    return true
end

local function names(items)
    local out = {}
    for _, item in ipairs(items) do out[#out + 1] = tostring(item:getDisplayName()) end
    return out
end

-- Swaps the table: offered player items go to the NPC, asked { { type, count } } come from
-- the NPC. No credit: nothing of the NPC's leaves unless the player puts something down in
-- the same swap ("unpaid"), the player's part moves first, and if anything fails to move
-- every move is undone, so either the whole trade happens or nothing does.
-- Returns true, givenNames (NPC -> player), receivedNames (player -> NPC), or false, reason.
function Hooks.executeTrade(record, shell, player, offeredItems, asked)
    -- In a fight: "combat" (play test, 2026-10-11: a gift handed over mid-fight read as "could not do it").
    if Hooks.inCombat(record) then return false, "combat" end
    if Hooks.stance(record, player) == "hostile" then return false, "refused" end
    if not Hooks.withinReach(player, shell, 6) or not Hooks.lineOfSight(player, shell) then return false, "too_far" end
    for _, item in ipairs(offeredItems) do
        if not Hooks.playerCanTrade(player, item) then return false, "changed" end
    end
    local available = {}
    for _, group in ipairs(Hooks.tradeableItems(shell, 64)) do available[group.type] = group.items end
    local fromNpc = {}
    for _, want in ipairs(asked) do
        local pool = available[want.type] or {}
        if #pool < want.count then return false, "changed" end
        for index = 1, want.count do fromNpc[#fromNpc + 1] = pool[index] end
    end
    if #fromNpc > 0 and #offeredItems == 0 then return false, "unpaid" end
    local journal, done = {}, false
    pcall(function()
        if not moveAll(offeredItems, shell:getInventory(), journal) then return end
        if not moveAll(fromNpc, player:getInventory(), journal) then return end
        done = true
    end)
    if not done then
        for index = #journal, 1, -1 do pcall(move, journal[index].item, journal[index].source) end
        return false, "refused"
    end
    return true, names(fromNpc), names(offeredItems)
end

-- Orders (server/.../Decisions/ALifeDecisionLoop.lua Decisions.setOrder; the "orders"
-- module obeys them, and threat responses still come first) --------------------------

local function decisions() return Hooks.available() and ProjectALife.DecisionLoop or nil end

function Hooks.orderFollow(record, player, ms)
    local loop = decisions()
    if loop == nil or type(loop.setOrder) ~= "function" then return false, "refused" end
    local ok, accepted, reason = pcall(loop.setOrder, record.uid, record.generation,
        { kind = "follow", player = player, untilMs = Hooks.nowMs() + ms })
    return ok and accepted == true, ok and reason or tostring(accepted)
end

function Hooks.orderStay(record, shell, ms)
    local loop = decisions()
    if loop == nil or type(loop.setOrder) ~= "function" then return false, "refused" end
    local ok, accepted, reason = pcall(function()
        local anchor = { x = shell:getX(), y = shell:getY(), z = shell:getZ() }
        return loop.setOrder(record.uid, record.generation, { kind = "hold", anchor = anchor, untilMs = Hooks.nowMs() + ms })
    end)
    return ok and accepted == true, ok and reason or tostring(accepted)
end

function Hooks.followingPlayer(record, player)
    local loop = decisions()
    local order = loop ~= nil and type(loop.orders) == "table" and loop.orders[record.uid] or nil
    return order ~= nil and order.kind == "follow" and order.player == player
        and (order.untilMs == nil or Hooks.nowMs() < order.untilMs)
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
-- Works in single player and for admins. factionId picks the faction (catalog ids such as
-- "alife_church_volunteers"); without it A-Life picks any faction, usually a hostile one.
-- persistent (default true): A-Life keeps them like a placed encounter (anchored). Without it
-- a debug spawn is expendable: once the player is away (dormant) for A-Life's "Unvisited NPC
-- lifetime" (sandbox, 8 world hours by default) it is deleted (play test, 2026-10-11).
function Hooks.spawnTestNpc(player, encounterId, count, distance, factionId, persistent)
    if player == nil or type(sendClientCommand) ~= "function" then return false, "no_player" end
    local x, y, z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    sendClientCommand(player, "ProjectALife", "alifeDiagnostics", { enabled = true, recorder = false })
    sendClientCommand(player, "ProjectALife", "debugSpawnCatalog", {
        encounterId = encounterId or "patrol",
        factionId = factionId,
        count = tonumber(count) or 1,
        x = x + (tonumber(distance) or 6), y = y, z = z,
        persistent = persistent ~= false,
    })
    return true
end

local function catalogName(profileId)
    local name = nil
    pcall(function()
        local profile = ProjectALife.Catalog.npc(profileId)
        if type(profile) == "table" and type(profile.general) == "table" then name = profile.general.name end
    end)
    return name
end

-- Kept by A-Life's population cleanup? The same test as its Population.expendable, plus the
-- groups its persistence keeps (squads, outposts).
local function keptByALife(memory)
    local admin = type(memory.admin) == "table" and memory.admin or nil
    return memory.persistent == true or (admin ~= nil and admin.persistent == true) or memory.adminAnchor == true
        or memory.encounter ~= nil or memory.squadId ~= nil or memory.outpostId ~= nil
end

-- Debug (read only): A-Life's actors as rows { uid, name, faction, lifecycle, kept, debug,
-- distance } nearest first, and counts per lifecycle.
function Hooks.actorSnapshot(player)
    local rows, counts = {}, {}
    local each = resolve("ActorRegistry.each")
    if type(each) ~= "function" then return rows, counts end
    local px, py = nil, nil
    if player ~= nil then pcall(function() px, py = player:getX(), player:getY() end) end
    local bindings = resolve("Watchdog.bindings")
    pcall(each, function(record)
        local memory = type(record.memory) == "table" and record.memory or {}
        local position = record.worldPosition
        local binding = type(bindings) == "table" and bindings[record.uid] or nil
        if record.lifecycle == "active" and type(binding) == "table" and binding.shell ~= nil then
            pcall(function() position = { x = binding.shell:getX(), y = binding.shell:getY() } end)
        end
        local distance = nil
        if px ~= nil and type(position) == "table" and tonumber(position.x) ~= nil and tonumber(position.y) ~= nil then
            distance = math.sqrt((position.x - px) ^ 2 + (position.y - py) ^ 2)
        end
        local lifecycle = tostring(record.lifecycle)
        counts[lifecycle] = (counts[lifecycle] or 0) + 1
        rows[#rows + 1] = { uid = record.uid, name = catalogName(record.profileId), faction = record.factionId,
            lifecycle = lifecycle, kept = keptByALife(memory), debug = memory.debugSpawn == true, distance = distance }
    end)
    table.sort(rows, function(a, b)
        if a.distance == nil then return false end
        if b.distance == nil then return true end
        return a.distance < b.distance
    end)
    return rows, counts
end

-- Keeping NPCs the player has met (Keeper.lua) -------------------------------------
-- A-Life writes only persistent groups into the save (Core/ALifePersistence.lua forSave:
-- squads of its offline ledger, outposts, and groups whose memory says persistent, up to the
-- sandbox "Saved group limit"); every other NPC lives for one session, and a dormant one is
-- also deleted after "Unvisited NPC lifetime" (World/ALifePopulation.lua expendable). The
-- same memory flag A-Life's own persistent encounters carry keeps an NPC: persistent = true,
-- written through Talk.writeMemory (a versioned registry update, saved with the world).
-- alifeBrainKeptAtMs marks the ones we kept, so Hooks.releaseKept can undo it.

-- uids of living A-Life NPCs within tiles of a player (A-Life's perception snapshot).
function Hooks.actorsNearPlayers(tiles)
    local snapshot = resolve("Perception.zombieSnapshot")
    local out = {}
    if type(snapshot) ~= "table" or type(snapshot.actors) ~= "table" then return out end
    local players = {}
    if type(getNumActivePlayers) == "function" then
        for index = 0, getNumActivePlayers() - 1 do
            local player = getSpecificPlayer(index)
            if player ~= nil and not player:isDead() then
                local px, py = xyzOf(player)
                if px ~= nil then players[#players + 1] = { x = px, y = py } end
            end
        end
    end
    for _, sampled in ipairs(snapshot.actors) do
        local sx, sy = tonumber(sampled.x), tonumber(sampled.y)
        if sx ~= nil then
            for _, at in ipairs(players) do
                if flatDistance(sx, sy, at.x, at.y) <= tiles then
                    local data = modDataOf(sampled.body)
                    local uid = data ~= nil and data.ProjectALifeUID or nil
                    if type(uid) == "string" then out[#out + 1] = uid end
                    break
                end
            end
        end
    end
    return out
end

-- Keeps the NPC and its whole group (A-Life saves by group; a half-kept squad would come back
-- split). Returns "kept" (with how many NPCs were marked) | "already" (A-Life keeps it) |
-- "managed" (offline squad or outpost task squad: A-Life brings those back itself) | nil, reason.
function Hooks.keepGroupOf(uid, now)
    local peek, each, current = resolve("ActorRegistry.peek"), resolve("ActorRegistry.each"), talk()
    if type(peek) ~= "function" or type(each) ~= "function" or current == nil or type(current.writeMemory) ~= "function" then
        return nil, "alife_unavailable"
    end
    local okRead, record = pcall(peek, uid)
    if not okRead or type(record) ~= "table" then return nil, "unknown" end
    if record.lifecycle == "dead" then return nil, "dead" end
    local memory = type(record.memory) == "table" and record.memory or {}
    if memory.sessionOnly == true or memory.outpostSquadId ~= nil or memory.squadId ~= nil then return "managed" end
    if keptByALife(memory) then return "already" end
    local members = { uid }
    local group = memory.groupId
    if group ~= nil then
        members = {}
        pcall(each, function(other)
            local theirs = type(other.memory) == "table" and other.memory or {}
            if theirs.groupId == group and other.lifecycle ~= "dead" and not keptByALife(theirs) then
                members[#members + 1] = other.uid
            end
        end)
    end
    local marked = 0
    for _, member in ipairs(members) do
        local ok, written = pcall(current.writeMemory, member, function(m)
            m.persistent = true
            m.alifeBrainKeptAtMs = now
        end)
        if ok and written == true then marked = marked + 1 end
    end
    if marked == 0 then return nil, "write_failed" end
    return "kept", marked
end

-- Groups A-Life will try to write into the save, against its limit (Persistence.squadCap):
-- the same grouping as Persistence.forSave, without its outpost-resident exception.
function Hooks.savedGroups()
    local each, cap = resolve("ActorRegistry.each"), resolve("Persistence.squadCap")
    local groups, count, ours = {}, 0, 0
    if type(each) ~= "function" then return 0, tonumber(cap), 0 end
    pcall(each, function(record)
        local m = type(record.memory) == "table" and record.memory or {}
        if record.lifecycle ~= "dead" and m.sessionOnly ~= true and m.outpostSquadId == nil and m.squadId == nil
                and keptByALife(m) then
            local id = m.outpostId ~= nil and ("outpost:" .. tostring(m.outpostId)) or tostring(m.groupId or m.encounter or record.uid)
            if not groups[id] then
                groups[id], count = true, count + 1
                if m.alifeBrainKeptAtMs ~= nil then ours = ours + 1 end
            end
        end
    end)
    return count, tonumber(cap), ours
end

-- Undoes our keeping (the NPCs A-Life did not keep on its own become expendable again).
function Hooks.releaseKept()
    local each, current = resolve("ActorRegistry.each"), talk()
    if type(each) ~= "function" or current == nil or type(current.writeMemory) ~= "function" then return 0 end
    local uids = {}
    pcall(each, function(record)
        if type(record.memory) == "table" and record.memory.alifeBrainKeptAtMs ~= nil then uids[#uids + 1] = record.uid end
    end)
    local released = 0
    for _, uid in ipairs(uids) do
        local ok, written = pcall(current.writeMemory, uid, function(m)
            m.persistent = nil
            m.alifeBrainKeptAtMs = nil
        end)
        if ok and written == true then released = released + 1 end
    end
    return released
end

-- Trust lets the player close (Rapport.lua) ------------------------------------------
-- A careful group (Relations.playerStance "careful", from the faction's view of the player)
-- warns a player who comes close and opens fire when the warnings are walked through
-- (Behaviours/ALifeModuleCareful.lua: keep back -> last warning -> hostile). A-Life's own way
-- out is memory.tolerateUntil[playerKey] = untilMs: while it lasts "careful" reads as
-- "neutral" (Decisions/ALifeRelations.lua) and the warnings stop. Talk.tolerate writes it for
-- the NPC's whole group or outpost; A-Life does so itself, for 8 minutes, when an NPC agrees
-- to walk together. Hostile stays hostile, and a hit still turns the group.

-- The group A-Life warns and tolerates as one (ModuleCareful's groupOf).
function Hooks.groupKey(record)
    local memory = type(record) == "table" and type(record.memory) == "table" and record.memory or {}
    if memory.outpostId ~= nil then return "outpost:" .. tostring(memory.outpostId) end
    if memory.groupId ~= nil then return tostring(memory.groupId) end
    return "solo:" .. tostring(type(record) == "table" and record.uid or nil)
end

-- A-Life's stored record (no copy), or nil.
function Hooks.peekRecord(uid)
    local peek = resolve("ActorRegistry.peek")
    if type(uid) ~= "string" or type(peek) ~= "function" then return nil end
    local ok, record = pcall(peek, uid)
    return ok and type(record) == "table" and record or nil
end

-- Until when (ms) the NPC tolerates the player, or nil.
function Hooks.toleratedUntil(record, player)
    local key = Hooks.playerKey(player)
    local memory = type(record) == "table" and type(record.memory) == "table" and record.memory or nil
    if key == nil or memory == nil or type(memory.tolerateUntil) ~= "table" then return nil end
    return tonumber(memory.tolerateUntil[key])
end

-- Writes the tolerance for the NPC's whole group; untilMs = now ends it.
function Hooks.tolerate(record, player, untilMs)
    local current, key = talk(), Hooks.playerKey(player)
    if current == nil or type(current.tolerate) ~= "function" or key == nil or type(record) ~= "table" then
        return false
    end
    return pcall(current.tolerate, record, key, untilMs) == true
end

function Hooks.nameOf(record)
    return type(record) == "table" and catalogName(record.profileId) or nil
end

-- Robberies (Robberies.lua) ------------------------------------------------------------
-- A-Life's ModuleRobbery keeps each robbery of a player in Robbery.active (id -> state:
-- members, player, phase, taken = item full types) until Robbery.finish removes it and
-- writes state.finishedReason ("released", "execute:<why>", "player_gone", "crew_gone",
-- "interrupted"). Read only: we keep the state tables we saw and report how each ended.

function Hooks.activeRobberies()
    local active = resolve("ModuleRobbery.active")
    return type(active) == "table" and active or {}
end

-- An NPC as the sidecar's events describe it, from A-Life's registry (no body needed).
function Hooks.describeRecord(uid)
    local peek = resolve("ActorRegistry.peek")
    if type(uid) ~= "string" or type(peek) ~= "function" then return nil end
    local ok, record = pcall(peek, uid)
    if not ok or type(record) ~= "table" then return { uid = uid } end
    local memory = type(record.memory) == "table" and record.memory or {}
    return { uid = uid, name = catalogName(record.profileId), factionId = record.factionId,
        groupId = memory.groupId, profileId = record.profileId }
end

-- The name a player sees for an item type ("Base.Hammer" -> "Hammer"), or the type.
function Hooks.itemName(fullType)
    local name = nil
    pcall(function()
        local item = getScriptManager():FindItem(fullType)
        if item ~= nil then name = item:getDisplayName() end
    end)
    return name or tostring(fullType)
end

Hooks.LIFECYCLE_EVENTS = { actor_removed = true, dead_actors_pruned = true, spawn_failed = true,
    spawn_rollback = true, orphan_shell_removed = true }

-- Debug (read only): A-Life's recent lifecycle telemetry (its ring buffer since this load)
-- and its counters, e.g. actor_removed { uid, reason = "dormant_ttl" }.
function Hooks.lifecycleEvents()
    local out = {}
    local events, counters = resolve("Telemetry.events"), resolve("Telemetry.counters")
    for _, event in ipairs(type(events) == "table" and events or {}) do
        if type(event) == "table" and Hooks.LIFECYCLE_EVENTS[event.category] then out[#out + 1] = event end
    end
    local totals = {}
    for category in pairs(Hooks.LIFECYCLE_EVENTS) do
        totals[category] = type(counters) == "table" and tonumber(counters[category]) or 0
    end
    return out, totals
end

function Hooks.isPlayer(object)
    local ok, result = pcall(function() return instanceof(object, "IsoPlayer") end)
    return ok and result == true
end

-- Decisions (phase 3: behavior cloning) --------------------------------------------
-- ModuleRegistry.evaluate runs A-Life's module chains ("decision" when nothing threatens
-- the NPC, "response" to a threat) and returns the winning state and module id; the
-- decision loop keeps only the state. The tap sees every full-chain run (not the
-- single-module "only" calls the loop makes during lulls) and only watches: whatever
-- A-Life chose is returned unchanged. A nil winner means A-Life's own fallback ran.

Hooks.DECISION_KINDS = { decision = true, response = true }

-- Phase 5: a chooser (Control.pick) may name one module of the chain before A-Life runs it.
-- That module then runs alone, the way A-Life's own lull calls do ("only"); if it has nothing
-- to do (nil), or the chooser names none, A-Life's whole chain runs as before. Modules start
-- movements and play voices while they evaluate, so the chain is never run first and then
-- overruled.
--
-- onDecision(kind, actor, shell, context, moduleId | nil, chosen) -- chosen: the chooser's pick ran
-- chooser(kind, actor, shell, context) -> module id | nil; onChosen(kind, actor, moduleId, ran)
function Hooks.installDecisionTap(onDecision)
    local registry = Hooks.available() and ProjectALife.ModuleRegistry or nil
    if registry == nil or type(registry.evaluate) ~= "function" then return false, "module_registry_unavailable" end
    Hooks.decisionTap = onDecision
    if Hooks.originalEvaluate ~= nil then return true, "already_installed" end
    local original = registry.evaluate
    Hooks.originalEvaluate = original
    registry.evaluate = Hooks.wrapEvaluate(original)
    return true, "installed"
end

-- The wrapped Registry.evaluate (kept apart so tests can run it on a fake original).
function Hooks.wrapEvaluate(original)
    local function tap(kind, actor, shell, context, moduleId, chosen)
        if type(Hooks.decisionTap) ~= "function" then return end
        local ok, failure = pcall(Hooks.decisionTap, kind, actor, shell, context, moduleId, chosen)
        if not ok then Hooks.decisionTapError = tostring(failure) end
    end
    return function(kind, actor, shell, context, only)
        local full = only == nil and Hooks.DECISION_KINDS[kind] == true
        if full and type(Hooks.decisionChooser) == "function" then
            local ok, choice = pcall(Hooks.decisionChooser, kind, actor, shell, context)
            if not ok then
                Hooks.decisionChooserError = tostring(choice)
            elseif type(choice) == "string" then
                local result, moduleId = original(kind, actor, shell, context, choice)
                if type(Hooks.decisionChosen) == "function" then
                    pcall(Hooks.decisionChosen, kind, actor, choice, result ~= nil)
                end
                if result ~= nil then
                    tap(kind, actor, shell, context, moduleId, true)
                    return result, moduleId
                end
            end
        end
        local result, moduleId = original(kind, actor, shell, context, only)
        if full then tap(kind, actor, shell, context, result ~= nil and moduleId or nil, false) end
        return result, moduleId
    end
end

-- chooser / onChosen as above; nil removes them (A-Life alone decides again).
function Hooks.setDecisionChooser(chooser, onChosen)
    Hooks.decisionChooser, Hooks.decisionChosen = chooser, onChosen
    return Hooks.originalEvaluate ~= nil
end

-- The modules of that chain this NPC may run (its behavior profile, conduct, switches).
function Hooks.allowedModules(kind, actor)
    local allowed = ALifeBrain.Json ~= nil and ALifeBrain.Json.array({}) or {}
    local registry = Hooks.available() and ProjectALife.ModuleRegistry or nil
    if registry == nil or type(registry.order) ~= "table" or type(registry.allows) ~= "function" then return allowed end
    for _, module in ipairs(registry.order) do
        if type(module) == "table" and module.dispatch == kind then
            local ok, yes = pcall(registry.allows, actor, module.id)
            if ok and yes == true then allowed[#allowed + 1] = tostring(module.id) end
        end
    end
    return allowed
end

local function armed(player)
    local yes = false
    pcall(function()
        local item = player:getPrimaryHandItem()
        yes = item ~= nil and instanceof(item, "HandWeapon") and tostring(item:getType()) ~= "BareHands"
    end)
    return yes
end

local function nearestPlayer(x, y)
    local best, bestDistance = nil, nil
    if x == nil or type(getNumActivePlayers) ~= "function" then return nil end
    for index = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(index)
        if player ~= nil and not player:isDead() then
            local px, py = xyzOf(player)
            if px ~= nil then
                local distance = flatDistance(x, y, px, py)
                if bestDistance == nil or distance < bestDistance then best, bestDistance = player, distance end
            end
        end
    end
    return best, bestDistance
end

-- The nearest living player to this body and the distance (tiles), or nil.
function Hooks.nearestPlayer(shell)
    local x, y = xyzOf(shell)
    return nearestPlayer(x, y)
end

-- A player's standing order to this NPC (DecisionLoop.orders: { kind = "follow" | "hold" |
-- "patrol", untilMs?, ... }) while it lasts, or nil.
function Hooks.orderOf(uid)
    local loop = decisions()
    local order = loop ~= nil and type(loop.orders) == "table" and loop.orders[uid] or nil
    if type(order) ~= "table" then return nil end
    if order.untilMs ~= nil and Hooks.nowMs() >= order.untilMs then return nil end
    return order
end

-- Plain zombies and other A-Life NPCs around the NPC, from the snapshot A-Life's perception
-- refreshes every 200 ms (Perception.zombieSnapshot: bodies / actors with x, y, z).
local function crowdAround(raw, actor, shell, x, y)
    local snapshot = resolve("Perception.zombieSnapshot")
    if type(snapshot) ~= "table" or x == nil then return end
    local near, around = 0, 0
    for _, sampled in ipairs(type(snapshot.bodies) == "table" and snapshot.bodies or {}) do
        local sx, sy = tonumber(sampled.x), tonumber(sampled.y)
        if sx ~= nil then
            local distance = flatDistance(x, y, sx, sy)
            if distance <= 25 then
                around = around + 1
                if distance <= 10 then near = near + 1 end
            end
        end
    end
    raw.zombiesNear, raw.zombiesAround = near, around
    local group = type(actor.memory) == "table" and actor.memory.groupId or nil
    local peek = resolve("ActorRegistry.peek")
    local squad, others = 0, 0
    for _, sampled in ipairs(type(snapshot.actors) == "table" and snapshot.actors or {}) do
        local sx, sy = tonumber(sampled.x), tonumber(sampled.y)
        if sampled.body ~= shell and sx ~= nil and flatDistance(x, y, sx, sy) <= 10 then
            local data = modDataOf(sampled.body)
            local uid = data ~= nil and data.ProjectALifeUID or nil
            local record = nil
            if type(uid) == "string" and type(peek) == "function" then
                local ok, found = pcall(peek, uid)
                record = ok and found or nil
            end
            local theirs = type(record) == "table" and type(record.memory) == "table" and record.memory.groupId or nil
            if group ~= nil and theirs == group then squad = squad + 1 else others = others + 1 end
        end
    end
    raw.squadNear, raw.othersNear = squad, others
end

-- What the NPC knows at a decision, as plain values for ALifeBrain.Features.vector.
function Hooks.decisionObservation(kind, actor, shell, context, now)
    local raw = {}
    local data = modDataOf(shell) or {}
    pcall(function() raw.health = shell:getHealth() end)
    raw.maxHealth = tonumber(data.ProjectALifeMaximumHealth)
    raw.wounds = tonumber(data.ProjectALifeWounds)
    local bleedAt, downedUntil = tonumber(data.ProjectALifeBleedOutAtMs), tonumber(data.ProjectALifeDownedUntilMs)
    raw.bleeding = bleedAt ~= nil and bleedAt > now
    raw.downed = downedUntil ~= nil and downedUntil > now
    raw.endurance, raw.enduranceMax = tonumber(data.ProjectALifeEndurance), tonumber(data.ProjectALifeEnduranceMaximum)
    raw.weaponClass = data.ProjectALifeWeaponClass
    raw.rounds = tonumber(data.ProjectALifeLoadedRounds)
    raw.jammed = data.ProjectALifeWeaponJammed == true
    local fearUntil, panicUntil = tonumber(data.ProjectALifeFearUntilMs), tonumber(data.ProjectALifePanicUntilMs)
    raw.afraid = (fearUntil ~= nil and fearUntil > now) or (panicUntil ~= nil and panicUntil > now)

    local x, y = xyzOf(shell)
    local threat = type(context) == "table" and context.threat or nil
    raw.threat = threat ~= nil
    if threat ~= nil then
        raw.threatKind = context.threatKind
        local tx, ty = xyzOf(threat)
        if tx ~= nil and x ~= nil then raw.threatDistance = flatDistance(x, y, tx, ty) end
    end
    crowdAround(raw, actor, shell, x, y)

    local player, distance = nearestPlayer(x, y)
    if player ~= nil then
        raw.playerDistance = distance
        raw.playerArmed = armed(player)
        pcall(function() raw.playerAiming = player:isAiming() == true end)
        raw.stance = Hooks.stance(actor, player)
    end
    pcall(function() raw.hour = getGameTime():getHour() + getGameTime():getMinutes() / 60 end)

    local loop = decisions()
    local uid = actor.uid
    if loop ~= nil then
        local order = type(loop.orders) == "table" and loop.orders[uid] or nil
        raw.order = type(order) == "table" and order.kind or nil
        local state = type(loop.states) == "table" and loop.states[uid] or nil
        raw.previous = type(state) == "table" and state.kind or nil
    end
    -- What conversations left (phase 5): trust / fear toward the player, the drive (-1..1).
    local dialogue = ALifeBrain.Dialogue
    local mind = dialogue ~= nil and dialogue.minds[uid] or nil
    if type(mind) == "table" then
        raw.trust, raw.fear = mind.trust, mind.fear
        raw.goal = dialogue.goalNow(mind, now) / 100
    end
    local memory = type(actor.memory) == "table" and actor.memory or {}
    raw.robbery = memory.robbery ~= nil
    raw.talkHold = (tonumber(memory.talkHoldUntilMs) or 0) > now
    return raw
end

-- Companion discipline (Companion.lua) -----------------------------------------------
-- An A-Life "response" module (runs when a threat is perceived, before A-Life fights it),
-- between A-Life's flee (30) and panic (34). A-Life only runs modules a behavior profile
-- lists in its overlays, so the id is added to every profile at run time (nothing saved,
-- no A-Life file changed); the module answers nil for anyone not following a player.

Hooks.COMPANION_PRIORITY = 32
Hooks.companionStats = { regroup = 0, fall_back = 0 }

local function zombiesWithin(x, y, radius)
    local snapshot = resolve("Perception.zombieSnapshot")
    local count = 0
    if type(snapshot) ~= "table" or x == nil then return 0 end
    for _, sampled in ipairs(type(snapshot.bodies) == "table" and snapshot.bodies or {}) do
        local sx, sy = tonumber(sampled.x), tonumber(sampled.y)
        if sx ~= nil and flatDistance(x, y, sx, sy) <= radius then count = count + 1 end
    end
    return count
end

-- Plain zombies within radius tiles of this body (EventLog: a player's hit on an NPC that is
-- fighting the dead was most likely meant for them).
function Hooks.zombiesNear(object, radius)
    local x, y = xyzOf(object)
    return zombiesWithin(x, y, radius)
end

-- Bodies of living A-Life NPCs within tiles of this object, at most limit (EventLog: who saw
-- the player kill a zombie right next to them).
function Hooks.npcBodiesNear(object, tiles, limit)
    local snapshot = resolve("Perception.zombieSnapshot")
    local out = {}
    local x, y = xyzOf(object)
    if type(snapshot) ~= "table" or type(snapshot.actors) ~= "table" or x == nil then return out end
    for _, sampled in ipairs(snapshot.actors) do
        local sx, sy = tonumber(sampled.x), tonumber(sampled.y)
        if sx ~= nil and sampled.body ~= object and flatDistance(x, y, sx, sy) <= tiles and Hooks.isNpc(sampled.body) then
            out[#out + 1] = sampled.body
            if #out >= (limit or 6) then break end
        end
    end
    return out
end

local function healthRatio(actor, shell)
    local survival = resolve("Survival")
    if type(survival) == "table" and type(survival.healthRatio) == "function" then
        local ok, ratio = pcall(survival.healthRatio, actor, shell)
        if ok and tonumber(ratio) ~= nil then return tonumber(ratio) end
    end
    local health, maximum = nil, tonumber((modDataOf(shell) or {}).ProjectALifeMaximumHealth) or 1
    pcall(function() health = shell:getHealth() end)
    return (tonumber(health) or maximum) / (maximum > 0 and maximum or 1)
end

local function hasFirearm(shell)
    local survival = resolve("Survival")
    if type(survival) == "table" and type(survival.hasFirearm) == "function" then
        local ok, yes = pcall(survival.hasFirearm, shell)
        if ok then return yes == true end
    end
    local class = (modDataOf(shell) or {}).ProjectALifeWeaponClass
    return class == "handgun" or class == "rifle"
end

-- The player an NPC follows on a player's order (ours or A-Life's own), or nil.
local function followedPlayer(actor, now)
    local loop = decisions()
    local order = loop ~= nil and type(loop.orders) == "table" and loop.orders[actor.uid] or nil
    if type(order) ~= "table" or order.kind ~= "follow" or order.source == "leader" or order.player == nil then return nil end
    if order.generation ~= nil and order.generation ~= actor.generation then return nil end
    if order.untilMs ~= nil and now >= order.untilMs then return nil end
    return order.player
end

-- A movement as a "retreat" state: A-Life's loop does not interrupt retreats every time it
-- sees the threat again (it does interrupt plain movement), so the NPC keeps going.
local function moveTo(context, actor, shell, target, reason, pace)
    if type(context.startMovement) ~= "function" then return nil end
    local state = context.startMovement(actor, shell, target, "companion_" .. reason, { kind = "retreat",
        activity = "moving", pace = pace or "run", timeoutMs = 8000, threat = context.threat,
        threatKind = context.threatKind })
    if state ~= nil then state.reason = "companion_" .. reason end
    return state
end

-- A point away from the threat (A-Life's own retreat geometry), or nil.
local function awayFrom(shell, threat, tiles)
    local survival = resolve("Survival")
    if type(survival) ~= "table" or type(survival.retreatTarget) ~= "function" then return nil end
    local ok, target = pcall(survival.retreatTarget, shell, threat, tiles)
    return ok and type(target) == "table" and target or nil
end

local function sneaking(player)
    local yes = false
    pcall(function() yes = player:isSneaking() == true end)
    return yes
end

local function running(player)
    local yes = false
    pcall(function() yes = player:isRunning() == true or player:isSprinting() == true end)
    return yes
end

-- What a follower facing a zombie should do (Companion.decide), as an A-Life state, or nil.
function Hooks.companionEvaluate(actor, shell, context)
    local Companion = ALifeBrain.Companion
    if Companion == nil or type(context) ~= "table" or context.threatKind ~= "zombie" or type(actor) ~= "table" then
        return nil
    end
    local now = tonumber(context.now) or Hooks.nowMs()
    local player = followedPlayer(actor, now)
    if player == nil then return nil end
    local x, y = xyzOf(shell)
    local px, py, pz = xyzOf(player)
    local tx, ty = xyzOf(context.threat)
    if x == nil or px == nil or tx == nil then return nil end
    local view = {
        following = true,
        threatKind = context.threatKind,
        threatFromPlayer = flatDistance(tx, ty, px, py),
        threatFromNpc = flatDistance(tx, ty, x, y),
        npcFromPlayer = flatDistance(x, y, px, py),
        closeZombies = zombiesWithin(x, y, Companion.settings.crowdRadius),
        firearm = hasFirearm(shell),
        health = healthRatio(actor, shell),
        sneaking = sneaking(player),
        playerRunning = running(player),
    }
    local action = Companion.decide(view, actor.uid, now)
    Hooks.companionLast = { uid = actor.uid, action = action, view = view }
    if action == nil then return nil end
    Hooks.companionStats[action] = (Hooks.companionStats[action] or 0) + 1
    local pace = Companion.pace(view, action)
    local towardPlayer = action == "regroup" or Companion.fallBackTo(view) == "player"
    local beside = view.npcFromPlayer <= Companion.settings.besideTiles
    if towardPlayer and beside and action == "regroup" then
        -- Already beside the player: stay, do not go after it.
        return { kind = "idle", intent = "companion_hold", cooldownUntilMs = now + 1200 }
    end
    if towardPlayer and not beside then
        -- (Beside the player and still swamped: get away instead, below.)
        local spot = { x = px, y = py, z = pz }
        local loop = decisions()
        if loop ~= nil and type(loop.followTarget) == "function" then
            local ok, target = pcall(loop.followTarget, shell, spot)
            if ok and type(target) == "table" then spot = target end
        end
        local state = moveTo(context, actor, shell, spot, action, pace)
        if state ~= nil then return state end
    end
    if action == "fall_back" then
        if pace == "walk" then
            -- Sneaking and nothing right on it: slip away quietly instead of A-Life's
            -- shouted sprint.
            local target = awayFrom(shell, context.threat, 8)
            local state = target ~= nil and moveTo(context, actor, shell, target, "slip_away", "walk") or nil
            if state ~= nil then return state end
        end
        if type(context.startRetreat) == "function" then
            return context.startRetreat(actor, shell, context.threat, context.threatKind, now, "companion_outnumbered")
        end
    end
    return nil
end

-- Followers sneak while their player sneaks: A-Life crouches an NPC (ALifeSneak, slower walk,
-- no sprint bursts) while Stealth.stanceActive(modData) is true, which it only is for its own
-- stealth conduct. The wrapper adds our followers, in the same combat phases.
function Hooks.wrapStealthStance()
    local stealth = resolve("Stealth")
    if type(stealth) ~= "table" or type(stealth.stanceActive) ~= "function" then return false, "stealth_unavailable" end
    if Hooks.originalStanceActive ~= nil then return true, "already_installed" end
    local original = stealth.stanceActive
    Hooks.originalStanceActive = original
    stealth.stanceActive = function(data)
        if original(data) then return true end
        local Companion = ALifeBrain.Companion
        if type(data) ~= "table" or Companion == nil or Companion.sneakers[data.ProjectALifeUID] ~= true then return false end
        local phase = tostring(data.ProjectALifeCombatPhase or "idle")
        return phase == "idle" or phase == "" or phase == "aborted" or phase == "approach" or phase == "cover"
    end
    return true, "installed"
end

-- Who sneaks now (called a few times a second).
function Hooks.updateFollowerStealth()
    local Companion = ALifeBrain.Companion
    local loop = decisions()
    if Companion == nil or loop == nil then return 0 end
    local count = 0
    for _ in pairs(Companion.refreshSneakers(loop.orders, sneaking)) do count = count + 1 end
    return count
end

-- Our A-Life modules -----------------------------------------------------------------
-- Registered through A-Life's own ModuleRegistry. A-Life only runs modules a behavior profile
-- lists in its overlays, so each id is added to every profile at run time (nothing saved, no
-- A-Life file changed; repeated now and then for profiles added later). Every module answers
-- nil, which leaves the decision to A-Life, unless its own case applies.
--   alifeBrainParley (29): a hostile NPC that sees the player talks first (Parley.lua)
--   alifeBrainStandoff (31): an NPC facing another NPC warns before shooting (Standoff.lua)
--   alifeBrainCompanion (32): a follower facing zombies keeps with the player (Companion.lua)
-- A-Life's own flee is 30 and panic 34.

local function voice(shell, event)
    local current = resolve("Voice")
    if type(current) == "table" and type(current.play) == "function" then
        pcall(current.play, shell, event, { force = true, ignoreBarkThrottle = true })
    end
end
Hooks.voice = voice

local function face(shell, target)
    pcall(function()
        local fence = resolve("AIFence")
        if type(fence) == "table" and type(fence.faceAimPoint) == "function" then
            fence.faceAimPoint(shell, target:getX(), target:getY(), Hooks.nowMs())
        else
            shell:faceThisObject(target)
        end
    end)
end

local function gesture(shell, name)
    local animations = resolve("Animations")
    if type(animations) == "table" and type(animations.apply) == "function" then pcall(animations.apply, shell, name) end
end

-- Did threat hit this NPC lately, or is it fighting it right now?
local function attackedBy(actor, shell, threat, threatUid, now)
    local perception = resolve("Perception")
    if type(perception) == "table" and type(perception.retaliationTarget) == "function" then
        local ok, attacker = pcall(perception.retaliationTarget, actor.uid, now)
        if ok and attacker ~= nil and attacker == threat then return true end
    end
    local loop = decisions()
    local theirs = loop ~= nil and type(loop.states) == "table" and loop.states[threatUid] or nil
    return type(theirs) == "table" and theirs.kind == "combat" and theirs.threat == shell
end

function Hooks.standoffEvaluate(actor, shell, context)
    local Standoff = ALifeBrain.Standoff
    if Standoff == nil or type(context) ~= "table" or context.threatKind ~= "actor" or type(actor) ~= "table" then
        return nil
    end
    local threat = context.threat
    local data = modDataOf(threat)
    local threatUid = data ~= nil and data.ProjectALifeUID or nil
    if type(threatUid) ~= "string" then return nil end
    local now = tonumber(context.now) or Hooks.nowMs()
    local x, y = xyzOf(shell)
    local tx, ty = xyzOf(threat)
    if x == nil or tx == nil then return nil end
    -- While a crew talks with the player nobody on either side starts shooting (the truce
    -- covers only the player; their follower and the crew would otherwise end the talk).
    local parley = ALifeBrain.Parley ~= nil and ALifeBrain.Parley.active or nil
    if parley ~= nil and (parley.crew[actor.uid] or parley.crew[threatUid]) and not attackedBy(actor, shell, threat, threatUid, now) then
        face(shell, threat)
        return { kind = "idle", intent = "standoff_parley", cooldownUntilMs = now + 700 }
    end
    local step, event, ignoreMs = Standoff.step(actor.uid .. ">" .. threatUid,
        { distance = flatDistance(x, y, tx, ty), attacked = attackedBy(actor, shell, threat, threatUid, now) }, now)
    if event ~= nil then voice(shell, event) end
    if step == "fight" then return nil end
    if step == "ignore" then
        -- Out of range, or they kept apart: A-Life stops seeing it as a threat for a while (being
        -- attacked clears that) and the NPC goes back to what it was doing.
        local ignore = resolve("Perception.ignore")
        if type(ignore) == "function" then pcall(ignore, actor.uid, threat, ignoreMs) end
        return { kind = "idle", intent = "standoff_part", cooldownUntilMs = now + 300 }
    end
    face(shell, threat)
    if step == "warn" then gesture(shell, "stop") end
    -- A follower backs off to its player instead of standing its ground.
    local player = followedPlayer(actor, now)
    if player ~= nil then
        local px, py, pz = xyzOf(player)
        if px ~= nil and flatDistance(x, y, px, py) > ALifeBrain.Companion.settings.besideTiles then
            local state = moveTo(context, actor, shell, { x = px, y = py, z = pz }, "standoff", "walk")
            if state ~= nil then return state end
        end
    end
    return { kind = "idle", intent = "standoff_" .. step, cooldownUntilMs = now + 700 }
end

-- Parley (Parley.lua) helpers ---------------------------------------------------------

-- The key A-Life's relations and reputation use for a player.
function Hooks.reputationKey(player)
    local key = resolve("Reputation.playerKey")
    if type(key) == "function" then
        local ok, value = pcall(key, player)
        if ok and value ~= nil then return value end
    end
    return Hooks.playerKey(player)
end

function Hooks.groupKey(actor)
    local memory = type(actor) == "table" and type(actor.memory) == "table" and actor.memory or {}
    return tostring(memory.groupId or ("solo:" .. tostring(actor.uid)))
end

-- Why this hostile NPC would rather shoot than talk, or nil.
function Hooks.parleyBlocked(actor, shell, player, now, tiles)
    if multiplayerClient() then return "multiplayer" end
    if Hooks.inCombat(actor) then return "fighting" end
    local memory = type(actor.memory) == "table" and actor.memory or {}
    if type(memory.robbery) == "table" then return "robbery" end -- A-Life's own hold-up runs
    local key = Hooks.reputationKey(player)
    if key ~= nil and type(memory.hostileToPlayerKeys) == "table" and memory.hostileToPlayerKeys[key] == true then
        return "grudge" -- attacked, or walked through its warnings
    end
    local reputation = resolve("Reputation.recordedStatus")
    if type(reputation) == "function" then
        local ok, earned = pcall(reputation, player, actor)
        if ok and earned == "hostile" then return "grudge" end
    end
    local inVehicle = false
    pcall(function() inVehicle = player:getVehicle() ~= nil end)
    if inVehicle then return "vehicle" end
    if not Hooks.withinReach(player, shell, tiles) then return "far" end
    if not Hooks.lineOfSight(player, shell) then return "unseen" end
    return nil
end

-- The NPC and its squad mates within tiles: { uid = true }.
function Hooks.crewOf(actor, shell, tiles)
    local crew = { [actor.uid] = true }
    local group = type(actor.memory) == "table" and actor.memory.groupId or nil
    local each = resolve("ActorRegistry.each")
    if group == nil or type(each) ~= "function" then return crew end
    local x, y = xyzOf(shell)
    pcall(each, function(record)
        if type(record) == "table" and record.lifecycle == "active" and type(record.memory) == "table"
                and record.memory.groupId == group then
            local where = type(record.worldPosition) == "table" and record.worldPosition or {}
            local rx, ry = tonumber(where.x), tonumber(where.y)
            if x == nil or rx == nil or flatDistance(x, y, rx, ry) <= tiles then crew[record.uid] = true end
        end
    end)
    return crew
end

-- A-Life's own post-robbery truce: Relations.hostileToPlayer is false for the player until
-- untilMs (nil clears it), so the crew does not shoot while it lasts.
function Hooks.truce(crew, player, untilMs)
    local current = talk()
    local key = Hooks.reputationKey(player)
    if current == nil or type(current.writeMemory) ~= "function" or key == nil then return false end
    for uid in pairs(crew) do
        pcall(current.writeMemory, uid, function(memory)
            if untilMs == nil then
                if type(memory.robberyTruce) == "table" then memory.robberyTruce[key] = nil end
            else
                if type(memory.robberyTruce) ~= "table" then memory.robberyTruce = {} end
                memory.robberyTruce[key] = untilMs
            end
        end)
    end
    return true
end

-- Makes the crew think again now (after the truce ends, that means facing the player).
function Hooks.rethink(crew)
    local loop = decisions()
    if loop == nil or type(loop.refreshDirective) ~= "function" then return end
    for uid in pairs(crew) do pcall(loop.refreshDirective, uid) end
end

function Hooks.parleyEvaluate(actor, shell, context)
    local Parley = ALifeBrain.Parley
    if Parley == nil or type(context) ~= "table" or context.threatKind ~= "player" or type(actor) ~= "table" then
        return nil
    end
    local player = context.threat
    if not Hooks.isPlayer(player) then return nil end
    local now = tonumber(context.now) or Hooks.nowMs()
    if Parley.consider(actor, shell, player, now) ~= "hold" then return nil end
    face(shell, player)
    return { kind = "idle", intent = "parley", cooldownUntilMs = now + 800 }
end

-- Registering ------------------------------------------------------------------------

Hooks.MODULES = {
    { id = "alifeBrainParley", priority = 29, label = "A-Life Brain: parley",
      summary = "A hostile NPC that sees the player calls out and talks (tribute, threats) before it shoots.",
      evaluate = function(actor, shell, context) return Hooks.parleyEvaluate(actor, shell, context) end },
    { id = "alifeBrainStandoff", priority = 31, label = "A-Life Brain: standoff",
      summary = "An NPC facing another NPC warns it off, warns again, then fights.",
      evaluate = function(actor, shell, context) return Hooks.standoffEvaluate(actor, shell, context) end },
    { id = "alifeBrainCompanion", priority = Hooks.COMPANION_PRIORITY, label = "A-Life Brain: companion",
      summary = "Followers stay with the player: no chasing far zombies, fall back from crowds and when badly hurt.",
      evaluate = function(actor, shell, context) return Hooks.companionEvaluate(actor, shell, context) end },
}

-- Registers our modules once and opens them in every behavior profile (safe to repeat).
-- Returns true, a note, or false, a reason.
function Hooks.installModules()
    local registry = Hooks.available() and ProjectALife.ModuleRegistry or nil
    if registry == nil or type(registry.register) ~= "function" then return false, "module_registry_unavailable" end
    local opened, added = 0, {}
    local profiles = resolve("BehaviorProfiles.definitions")
    for _, module in ipairs(Hooks.MODULES) do
        for _, profile in ipairs(type(profiles) == "table" and profiles or {}) do
            if type(profile) == "table" then
                if type(profile.overlays) ~= "table" then profile.overlays = {} end
                if profile.overlays[module.id] ~= true then
                    profile.overlays[module.id] = true
                    opened = opened + 1
                end
            end
        end
        if type(registry.modules) ~= "table" or registry.modules[module.id] == nil then
            local ok, reason = registry.register({ id = module.id, label = module.label, summary = module.summary,
                kind = "reaction", dispatch = "response", priority = module.priority, evaluate = module.evaluate })
            if not ok then return false, module.id .. ": " .. tostring(reason) end
            added[#added + 1] = module.id
        end
    end
    if #added == 0 then return true, "already_installed (" .. tostring(opened) .. " profile entries opened)" end
    return true, table.concat(added, ", ") .. " in " .. tostring(opened) .. " profile entries"
end

return Hooks

