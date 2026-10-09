-- The trade table in the conversation window: items the player offers (they stay in the
-- player's inventory until a deal goes through) and items asked from the NPC (by type).
-- The NPC may counter with its own items and name what it wants back ("wanted"), which is
-- filled in from the player's things; a deal never lets the NPC's side go without the
-- player's (canAccept). Pure state; Hooks.executeTrade does the actual swap, both sides at
-- once. Spec: docs/bridge-protocol.md.

require "ALifeBrain/Json"

ALifeBrain = ALifeBrain or {}

local Trade = { MAX_ITEMS = 10 }
Trade.__index = Trade
ALifeBrain.Trade = Trade

-- info(item) -> { id, type, name, tex } (Hooks.itemInfo in game, a stub in tests).
function Trade.new(info)
    local self = setmetatable({}, Trade)
    self.info = info or function(item) return ALifeBrain.Hooks.itemInfo(item) end
    self:clear()
    return self
end

function Trade:clear()
    self.offered = {}
    self.asked = {}
    self.wanted = {}
    self.npcProposed = false
    self.version = (self.version or 0) + 1
end

-- Any change by the player voids the NPC's proposal (and what it wanted for it).
function Trade:touch()
    self.npcProposed = false
    self.wanted = {}
    self.version = self.version + 1
end

function Trade:isEmpty()
    return #self.offered == 0 and #self.asked == 0
end

function Trade:wantsMet()
    for _, want in ipairs(self.wanted) do
        if not want.met then return false end
    end
    return true
end

-- The player may take the NPC's proposal as it stands: everything it wanted is on the
-- table, and if the NPC gives anything the player gives something too.
function Trade:canAccept()
    if not self.npcProposed or self:isEmpty() or not self:wantsMet() then return false end
    return #self.asked == 0 or #self.offered > 0
end

-- Adds items to the player's side. check(item) may refuse with a reason. Returns added, refusals.
function Trade:offer(items, check)
    local added, refusals = 0, {}
    local present = {}
    for _, entry in ipairs(self.offered) do present[entry.id] = true end
    for _, item in ipairs(items or {}) do
        local info = self.info(item)
        if info ~= nil and not present[info.id] then
            local ok, reason = true, nil
            if check ~= nil then ok, reason = check(item) end
            if not ok then
                refusals[#refusals + 1] = reason
            elseif #self.offered >= Trade.MAX_ITEMS then
                refusals[#refusals + 1] = "full"
            else
                self.offered[#self.offered + 1] = { item = item, id = info.id, type = info.type, name = info.name, tex = info.tex }
                present[info.id] = true
                added = added + 1
            end
        end
    end
    if added > 0 then self:touch() end
    return added, refusals
end

-- Takes one item of this type back from the player's side.
function Trade:withdraw(itemType)
    for index = #self.offered, 1, -1 do
        if self.offered[index].type == itemType then
            table.remove(self.offered, index)
            self:touch()
            return true
        end
    end
    return false
end

-- Drops offered items that check(item) no longer allows (moved away, dropped, put to use).
-- Returns how many left the table.
function Trade:prune(check)
    local removed = 0
    for index = #self.offered, 1, -1 do
        if not check(self.offered[index].item) then
            table.remove(self.offered, index)
            removed = removed + 1
        end
    end
    if removed > 0 then self:touch() end
    return removed
end

local function askedIndex(self, itemType)
    for index, entry in ipairs(self.asked) do
        if entry.type == itemType then return index end
    end
    return nil
end

function Trade:askedCount(itemType)
    local index = askedIndex(self, itemType)
    return index and self.asked[index].count or 0
end

-- Asks one more of an NPC group (wrapping back to none after the last one); delta = -1 asks one less.
function Trade:ask(group, delta)
    delta = delta or 1
    local index = askedIndex(self, group.type)
    local count = (index and self.asked[index].count or 0) + delta
    if delta > 0 and count > group.count then count = 0 end
    if count < 0 then count = 0 end
    local total = 0
    for _, entry in ipairs(self.asked) do if entry.type ~= group.type then total = total + entry.count end end
    if count > 0 and total + count > Trade.MAX_ITEMS then return false end
    if index ~= nil and count == 0 then
        table.remove(self.asked, index)
    elseif index ~= nil then
        self.asked[index].count = count
    elseif count > 0 then
        self.asked[#self.asked + 1] = { type = group.type, name = group.name, count = count }
    end
    self:touch()
    return true
end

-- Puts one of the player's items named name on their side: one they had already put down
-- (previous) first, else one from playerGroups. taken holds the ids already used.
-- Returns true when the table now holds it.
local function fillWant(self, name, previous, playerGroups, taken)
    for _, entry in ipairs(previous) do
        if entry.name == name and not taken[entry.id] then
            taken[entry.id] = true
            self.offered[#self.offered + 1] = entry
            return true
        end
    end
    for _, group in ipairs(playerGroups or {}) do
        if group.name == name then
            for _, item in ipairs(group.items or {}) do
                local info = self.info(item)
                if info ~= nil and not taken[info.id] then
                    taken[info.id] = true
                    self.offered[#self.offered + 1] = { item = item, id = info.id, type = info.type, name = info.name,
                        tex = info.tex }
                    return true
                end
            end
        end
    end
    return false
end

-- The NPC's counter-offer: it puts these (by display name) on the table instead. When it
-- also names what it wants back (the player's things, by display name), the player's side
-- becomes exactly that, filled in from what they had put down and then from playerGroups
-- (Hooks.playerTradeableItems rows; nothing moves until the player accepts). Without wants
-- the player's side stays as it was. groups are Hooks.tradeableItems rows. Returns the
-- offered names that matched and the wanted names the player does not have.
function Trade:applyCounter(names, groups, wants, playerGroups)
    self.asked = {}
    local matched = {}
    for _, name in ipairs(names or {}) do
        for _, group in ipairs(groups or {}) do
            if group.name == name and askedIndex(self, group.type) == nil then
                self.asked[#self.asked + 1] = { type = group.type, name = group.name, count = 1 }
                matched[#matched + 1] = name
                break
            end
        end
    end
    self.wanted = {}
    local missing = {}
    local wanted = {}
    for _, name in ipairs(wants or {}) do
        if type(name) == "string" and #wanted < Trade.MAX_ITEMS then wanted[#wanted + 1] = name end
    end
    if #wanted > 0 then
        local previous, taken = self.offered, {}
        self.offered = {}
        for _, name in ipairs(wanted) do
            local met = fillWant(self, name, previous, playerGroups, taken)
            self.wanted[#self.wanted + 1] = { name = name, met = met }
            if not met then missing[#missing + 1] = name end
        end
    end
    self.version = self.version + 1
    self.npcProposed = true
    return matched, missing
end

-- What the NPC wants that is not on the table (shown as placeholders on the player's side).
function Trade:missingWants()
    local out = {}
    for _, want in ipairs(self.wanted) do
        if not want.met then out[#out + 1] = want.name end
    end
    return out
end

-- Groups the player's side by type for display and for the sidecar.
function Trade:offeredGroups()
    local groups, byType = {}, {}
    for _, entry in ipairs(self.offered) do
        local group = byType[entry.type]
        if group == nil then
            group = { type = entry.type, name = entry.name, count = 0, tex = entry.tex }
            byType[entry.type] = group
            groups[#groups + 1] = group
        end
        group.count = group.count + 1
    end
    return groups
end

function Trade:offeredItems()
    local items = {}
    for _, entry in ipairs(self.offered) do items[#items + 1] = entry.item end
    return items
end

local function lines(groups)
    local out = ALifeBrain.Json.array({})
    for _, group in ipairs(groups) do out[#out + 1] = { name = group.name, count = group.count } end
    return out
end

-- The "trade" object of a dialogue request.
function Trade:describe()
    return { playerOffer = lines(self:offeredGroups()), npcSide = lines(self.asked) }
end

-- NPC inventory summary for the dialogue request (npc.tradeable).
function Trade.lines(groups)
    return lines(groups or {})
end

return Trade
