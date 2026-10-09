require "ALifeBrain/Json"
require "ALifeBrain/Trade"
require "ALifeBrain/ALifeBrainHooks"
require "ALifeBrain/Tests/TestRunner"

local Json, Trade = ALifeBrain.Json, ALifeBrain.Trade

-- Fake items are plain tables; info() reads them directly.
local function item(id, itemType, name) return { id = id, type = itemType, name = name } end
local function newTrade() return Trade.new(function(entry) return entry end) end
local beans = { type = "Base.Beans", name = "Beans", count = 3 }
local hammer = { type = "Base.Hammer", name = "Hammer", count = 1 }

ALifeBrain.Tests.suite("Trade", {
    { "starts empty and describes itself as JSON arrays", function(check)
        local trade = newTrade()
        check.truthy(trade:isEmpty())
        check.equal(Json.encode(trade:describe()), "{\"npcSide\":[],\"playerOffer\":[]}")
    end },

    { "offers items once and groups them by type", function(check)
        local trade = newTrade()
        local a, b, c = item(1, "Base.Bandage", "Bandage"), item(2, "Base.Bandage", "Bandage"), item(3, "Base.Nails", "Nails")
        local added = trade:offer({ a, b, a, c })
        check.equal(added, 3, "the same item is not offered twice")
        check.same(trade:describe().playerOffer, { { name = "Bandage", count = 2 }, { name = "Nails", count = 1 } })
        check.equal(#trade:offeredItems(), 3)
        check.truthy(trade:withdraw("Base.Bandage"))
        check.same(trade:describe().playerOffer, { { name = "Bandage", count = 1 }, { name = "Nails", count = 1 } })
    end },

    { "passes refusals through and caps the table", function(check)
        local trade = newTrade()
        local items = {}
        for index = 1, 12 do items[index] = item(index, "Base.Nails", "Nails") end
        items[1] = item(99, "Base.Axe", "Axe")
        local added, refusals = trade:offer(items, function(entry)
            if entry.type == "Base.Axe" then return false, "equipped" end
            return true
        end)
        check.equal(added, Trade.MAX_ITEMS)
        check.equal(refusals[1], "equipped")
        check.equal(refusals[#refusals], "full")
    end },

    { "asks NPC items by count and wraps around", function(check)
        local trade = newTrade()
        trade:ask(beans)
        trade:ask(beans)
        check.equal(trade:askedCount("Base.Beans"), 2)
        trade:ask(beans, -1)
        check.equal(trade:askedCount("Base.Beans"), 1)
        trade:ask(hammer)
        trade:ask(hammer)
        check.equal(trade:askedCount("Base.Hammer"), 0, "past the last one it goes back to none")
        check.same(trade:describe().npcSide, { { name = "Beans", count = 1 } })
    end },

    { "every change invalidates an NPC proposal", function(check)
        local trade = newTrade()
        local matched = trade:applyCounter({ "Beans", "Rifle" }, { beans, hammer })
        check.same(matched, { "Beans" }, "only things the NPC really carries")
        check.truthy(trade.npcProposed)
        local version = trade.version
        trade:offer({ item(1, "Base.Bandage", "Bandage") })
        check.equal(trade.npcProposed, false)
        check.truthy(trade.version > version)
    end },

    { "prune drops items the player no longer has", function(check)
        local trade = newTrade()
        local kept, gone = item(1, "Base.Bandage", "Bandage"), item(2, "Base.Nails", "Nails")
        trade:offer({ kept, gone })
        trade:applyCounter({ "Beans" }, { beans })
        local version = trade.version
        check.equal(trade:prune(function(entry) return entry ~= gone end), 1)
        check.same(trade:describe().playerOffer, { { name = "Bandage", count = 1 } })
        check.equal(trade.npcProposed, false, "a changed table voids the NPC's proposal")
        check.truthy(trade.version > version)
        version = trade.version
        check.equal(trade:prune(function() return true end), 0)
        check.equal(trade.version, version, "nothing removed, nothing changed")
    end },

    { "clear empties both sides", function(check)
        local trade = newTrade()
        trade:offer({ item(1, "Base.Bandage", "Bandage") })
        trade:ask(beans)
        trade:clear()
        check.truthy(trade:isEmpty())
    end },

    { "a counter with wants sets the player's side to exactly that", function(check)
        local trade = newTrade()
        local nails, bandage = item(1, "Base.Nails", "Nails"), item(2, "Base.Bandage", "Bandage")
        trade:offer({ nails })
        local playerGroups = { { type = "Base.Bandage", name = "Bandage", count = 1, items = { bandage } } }
        local matched, missing = trade:applyCounter({ "Beans" }, { beans }, { "Bandage", "Rifle" }, playerGroups)
        check.same(matched, { "Beans" })
        check.same(missing, { "Rifle" })
        check.same(trade:describe().playerOffer, { { name = "Bandage", count = 1 } }, "the nails are taken back")
        check.same(trade:missingWants(), { "Rifle" })
        check.equal(trade:canAccept(), false, "not everything it wants is there")
        trade:applyCounter({ "Beans" }, { beans }, { "Bandage" }, playerGroups)
        check.truthy(trade:canAccept())
        trade:withdraw("Base.Bandage")
        check.equal(trade:canAccept(), false, "taking the payment back voids the deal")
        check.same(trade:missingWants(), {})
    end },

    { "a counter without wants keeps the player's side, and never goes unpaid", function(check)
        local trade = newTrade()
        trade:applyCounter({ "Beans" }, { beans })
        check.equal(trade:canAccept(), false, "the NPC's beans for nothing")
        local bandage = item(2, "Base.Bandage", "Bandage")
        trade:offer({ bandage })
        trade:applyCounter({ "Beans" }, { beans })
        check.same(trade:describe().playerOffer, { { name = "Bandage", count = 1 } })
        check.truthy(trade:canAccept())
        local gift = newTrade()
        gift:applyCounter({}, {}, { "Bandage" }, { { type = "Base.Bandage", name = "Bandage", count = 1, items = { bandage } } })
        check.truthy(gift:canAccept(), "the NPC may ask for a gift; nothing of its own leaves")
    end },
})

-- Hooks.executeTrade on stand-ins for the game's containers and items -----------------

local function fakeContainer(refuse)
    local container = { list = {}, refuse = refuse or {} }
    function container:getItems()
        local list = self.list
        return { size = function() return #list end, get = function(_, index) return list[index + 1] end }
    end
    function container:Remove(entry)
        for index = #self.list, 1, -1 do if self.list[index] == entry then table.remove(self.list, index) end end
        entry.container = nil
    end
    function container:AddItem(entry)
        if self.refuse[entry] then return nil end
        self.list[#self.list + 1] = entry
        entry.container = self
        return entry
    end
    function container:containsRecursive(entry)
        for _, other in ipairs(self.list) do if other == entry then return true end end
        return false
    end
    function container:setDrawDirty() end
    return container
end

local function fakeItem(id, itemType, name, container)
    local entry = { id = id, type = itemType, name = name }
    function entry:getID() return self.id end
    function entry:getFullType() return self.type end
    function entry:getDisplayName() return self.name end
    function entry:getTex() return nil end
    function entry:getContainer() return self.container end
    function entry:isFavorite() return false end
    function entry:IsInventoryContainer() return false end
    function entry:getAttachedSlot() return -1 end
    function entry:isEquipped() return false end
    container:AddItem(entry)
    return entry
end

local function fakeOwner(container)
    local owner = { inventory = container }
    function owner:getInventory() return self.inventory end
    function owner:getPrimaryHandItem() return nil end
    function owner:getSecondaryHandItem() return nil end
    function owner:isEquipped() return false end
    function owner:getWornItems() return { contains = function() return false end } end
    return owner
end

-- Runs body with the A-Life checks (combat, stance, distance) stubbed out, then restores them.
local function withHooks(body)
    local Hooks = ALifeBrain.Hooks
    local saved = { Hooks.inCombat, Hooks.stance, Hooks.withinReach, Hooks.lineOfSight }
    Hooks.inCombat = function() return false end
    Hooks.stance = function() return "neutral" end
    Hooks.withinReach = function() return true end
    Hooks.lineOfSight = function() return true end
    local ok, err = pcall(body, Hooks)
    Hooks.inCombat, Hooks.stance, Hooks.withinReach, Hooks.lineOfSight = saved[1], saved[2], saved[3], saved[4]
    if not ok then error(err) end
end

local function holds(container, entry) return entry.container == container and container:containsRecursive(entry) end

ALifeBrain.Tests.suite("TradeExecution", {
    { "both sides change hands, the player's first", function(check) withHooks(function(Hooks)
        local mine, theirs = fakeContainer(), fakeContainer()
        local bandage = fakeItem(1, "Base.Bandage", "Bandage", mine)
        local can = fakeItem(2, "Base.Beans", "Beans", theirs)
        local ok, given, received = Hooks.executeTrade({}, fakeOwner(theirs), fakeOwner(mine), { bandage },
            { { type = "Base.Beans", count = 1 } })
        check.equal(ok, true)
        check.same(given, { "Beans" })
        check.same(received, { "Bandage" })
        check.truthy(holds(theirs, bandage))
        check.truthy(holds(mine, can))
    end) end },

    { "nothing of the NPC's leaves unpaid", function(check) withHooks(function(Hooks)
        local mine, theirs = fakeContainer(), fakeContainer()
        local can = fakeItem(2, "Base.Beans", "Beans", theirs)
        local ok, reason = Hooks.executeTrade({}, fakeOwner(theirs), fakeOwner(mine), {}, { { type = "Base.Beans", count = 1 } })
        check.equal(ok, false)
        check.equal(reason, "unpaid")
        check.truthy(holds(theirs, can))
    end) end },

    { "a swap that cannot finish is undone", function(check) withHooks(function(Hooks)
        local theirs = fakeContainer()
        local can = fakeItem(2, "Base.Beans", "Beans", theirs)
        local mine = fakeContainer({ [can] = true })
        local bandage = fakeItem(1, "Base.Bandage", "Bandage", mine)
        local ok, reason = Hooks.executeTrade({}, fakeOwner(theirs), fakeOwner(mine), { bandage },
            { { type = "Base.Beans", count = 1 } })
        check.equal(ok, false)
        check.equal(reason, "refused")
        check.truthy(holds(mine, bandage), "the payment came back")
        check.truthy(holds(theirs, can), "the NPC kept its beans")
    end) end },
})
