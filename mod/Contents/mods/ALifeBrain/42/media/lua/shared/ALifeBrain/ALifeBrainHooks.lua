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
    if Hooks.inCombat(record) or Hooks.stance(record, player) == "hostile" then return false, "refused" end
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
    if Hooks.inCombat(record) or Hooks.stance(record, player) == "hostile" then return false, "refused" end
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
function Hooks.spawnTestNpc(player, encounterId, count, distance, factionId)
    if player == nil or type(sendClientCommand) ~= "function" then return false, "no_player" end
    local x, y, z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    sendClientCommand(player, "ProjectALife", "alifeDiagnostics", { enabled = true, recorder = false })
    sendClientCommand(player, "ProjectALife", "debugSpawnCatalog", {
        encounterId = encounterId or "patrol",
        factionId = factionId,
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
