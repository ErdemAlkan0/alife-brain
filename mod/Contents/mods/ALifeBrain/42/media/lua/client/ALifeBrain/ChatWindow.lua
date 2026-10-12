-- Conversation window, modelled on A-Life's own (client/.../Talk/ALifeTalkMenu.lua) but driven
-- by the player's own words. Earlier conversation with the NPC is loaded from the sidecar and
-- shown at the top; new lines follow below. A trade table on the right lets both sides put
-- items up: the player drags items in from the inventory (vanilla or Inventory Tetris), the
-- player asks for NPC items by clicking them, and the NPC can counter with its own items.
--
-- Opens with the chat key (T) when a talkable A-Life NPC is within 6 tiles and the sidecar can
-- answer (A-Life's own talk box otherwise), or from the right-click menu.
-- While open the NPC is held in conversation (A-Life's talk hold), so A-Life's greetings do
-- not cut in; closing it quiets them for a few minutes.

require "ISUI/ISCollapsableWindow"
require "ISUI/ISPanel"
require "ISUI/ISRichTextPanel"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "ISUI/ISUI3DModel"
require "ALifeBrain/Json"
require "ALifeBrain/Text"
require "ALifeBrain/Trade"
require "ALifeBrain/ALifeBrainHooks"
require "ALifeBrain/Dialogue"
require "ALifeBrain/Parley"
require "ALifeBrain/Pause"

ALifeBrain = ALifeBrain or {}

local Hooks, Dialogue, T, Trade = ALifeBrain.Hooks, ALifeBrain.Dialogue, ALifeBrain.Text, ALifeBrain.Trade

local Chat = {
    instance = nil,
    transcripts = {},
    settings = { reachTiles = 6, keepAliveMs = 2000, holdMs = 6000, quietAfterMs = 180000, maxLines = 120,
        historyLimit = 60, width = 660, minChatWidth = 460, tradeWidth = 340, height = 720, closeDelayMs = 2500,
        coneDegrees = 60 },
}
ALifeBrain.Chat = Chat

local Window = ISCollapsableWindow:derive("ALifeBrainChatWindow")
Chat.Window = Window

-- Same palette as A-Life's conversation window.
local COLORS = {
    player = " <RGB:0.82,0.68,0.40> ",
    npc = " <RGB:0.78,0.84,0.72> ",
    text = " <RGB:0.88,0.88,0.82> ",
    system = " <RGB:0.62,0.64,0.58> ",
    earlier = " <RGB:0.45,0.48,0.43> ",
}

local function nowMs() return getTimestampMs() end

local function plain(text)
    return (string.gsub(tostring(text or ""), "[<>]", function(c) return c == "<" and "(" or ")" end))
end

-- Drag and drop: vanilla inventory panes and Inventory Tetris both keep the drag in ISMouseDrag;
-- Tetris adds helpers that normalise its stacks. Receivers end the drag themselves.
local function tetrisDrag()
    if Chat.tetrisChecked then return Chat.tetris end
    Chat.tetrisChecked = true
    local active = false
    pcall(function() active = getActivatedMods():contains("INVENTORY_TETRIS") == true end)
    if active then
        local ok, module = pcall(require, "InventoryTetris/System/DragAndDrop")
        if ok and type(module) == "table" then Chat.tetris = module end
    end
    return Chat.tetris
end

function Chat.isDragging()
    return ISMouseDrag ~= nil and ISMouseDrag.dragging ~= nil
end

function Chat.draggedItems()
    if not Chat.isDragging() then return {} end
    local stacks = ISMouseDrag.dragging
    local tetris = tetrisDrag()
    if tetris ~= nil and type(tetris.getDraggedStacks) == "function" then
        local ok, normalized = pcall(tetris.getDraggedStacks)
        if ok and normalized ~= nil then stacks = normalized end
    end
    if instanceof(stacks, "InventoryItem") then return { stacks } end
    if type(stacks) == "table" and stacks.items ~= nil then stacks = { stacks } end
    local ok, items = pcall(ISInventoryPane.getActualItems, stacks)
    return ok and type(items) == "table" and items or {}
end

-- Ends the drag the way vanilla drop targets do (ISInventoryPage:onMouseUp): the source list
-- pane's own onMouseUp resets its drag state. Skipping that left the pane half-dragging
-- (rows greyed out, no tooltips, items picked up again on the next mouse move). Then
-- Tetris's own drag state, then the selections, as after any vanilla transfer.
function Chat.endDrag()
    local focus = ISMouseDrag.draggingFocus
    if type(focus) == "table" and type(focus.onMouseUp) == "function" then pcall(focus.onMouseUp, focus, 0, 0) end
    ISMouseDrag.draggingFocus = nil
    local tetris = tetrisDrag()
    if tetris ~= nil and type(tetris.endDrag) == "function" then pcall(tetris.endDrag) end
    ISMouseDrag.dragging = nil
    ISMouseDrag.itemsToDrag = nil
    ISMouseDrag.dragOwner = nil
    pcall(function()
        getPlayerInventory(0).inventoryPane.selected = {}
        getPlayerLoot(0).inventoryPane.selected = {}
    end)
end

-- The top-level UI element under the mouse (UIManager draws the list in order, last on top).
function Chat.topUiAtMouse()
    local found = nil
    pcall(function()
        local mx, my = getMouseX(), getMouseY()
        local uis = UIManager.getUI()
        for index = uis:size() - 1, 0, -1 do
            local ui = uis:get(index)
            if ui:isPointOver(mx, my) then found = ui; return end
        end
    end)
    return found
end

-- Trade box: rows with an icon, a name and a count; the player's box takes drops ------------

local TradeBox = ISPanel:derive("ALifeBrainTradeBox")
Chat.TradeBox = TradeBox

function TradeBox:new(x, y, width, height, owner, side)
    local o = ISPanel.new(self, x, y, width, height)
    o.owner, o.side = owner, side
    o.rows, o.offset = {}, 0
    o.rowHeight = math.max(24, getTextManager():getFontHeight(UIFont.Small) + 8)
    o.moveWithMouse = false
    o.backgroundColor = { r = 0.015, g = 0.02, b = 0.017, a = 0.85 }
    o.borderColor = { r = 0.2, g = 0.25, b = 0.2, a = 1 }
    return o
end

function TradeBox:setRows(rows, emptyText)
    self.rows, self.emptyText = rows or {}, emptyText
    local most = math.max(0, #self.rows - self:visibleRows())
    if self.offset > most then self.offset = most end
end

function TradeBox:visibleRows()
    return math.max(1, math.floor((self.height - 4) / self.rowHeight))
end

function TradeBox:prerender()
    ISPanel.prerender(self)
    if Chat.isDragging() and self:isMouseOver() then
        self:drawRectBorder(0, 0, self.width, self.height, 1, 0.82, 0.68, 0.40)
        self:drawRect(1, 1, self.width - 2, self.height - 2, 0.08, 0.82, 0.68, 0.40)
    end
end

function TradeBox:render()
    local fontHeight = getTextManager():getFontHeight(UIFont.Small)
    if #self.rows == 0 and self.emptyText ~= nil then
        self:drawText(self.emptyText, 8, 6, 0.45, 0.48, 0.43, 1, UIFont.Small)
        return
    end
    for index = 1, self:visibleRows() do
        local row = self.rows[index + self.offset]
        if row == nil then break end
        local y = 2 + (index - 1) * self.rowHeight
        if row.highlight ~= nil then
            local c = row.highlight
            self:drawRect(1, y, self.width - 2, self.rowHeight - 1, 0.22, c[1], c[2], c[3])
        end
        if row.tex ~= nil then pcall(function() self:drawTextureScaledAspect(row.tex, 4, y + 2, 20, 20, 1, 1, 1, 1) end) end
        local textY = y + (self.rowHeight - fontHeight) / 2
        local shade = row.dim and 0.5 or 0.88
        self:drawText(plain(row.label), 28, textY, shade, shade, shade - 0.06, 1, UIFont.Small)
        if row.right ~= nil then
            local width = getTextManager():MeasureStringX(UIFont.Small, row.right)
            self:drawText(row.right, self.width - 8 - width, textY, 0.66, 0.59, 0.39, 1, UIFont.Small)
        end
    end
end

function TradeBox:rowAt(y)
    return self.rows[math.floor((y - 2) / self.rowHeight) + 1 + self.offset]
end

-- A drop on either box is an offer (a drop on the NPC's box used to count as a click on a row).
function TradeBox:onMouseUp(x, y)
    if Chat.isDragging() then
        local items = Chat.draggedItems()
        Chat.endDrag()
        self.owner:onTradeDrop(items)
        return true
    end
    local row = self:rowAt(y)
    if row ~= nil then self.owner:onTradeClick(self.side, row, 1) end
    return true
end

function TradeBox:onRightMouseUp(x, y)
    local row = self:rowAt(y)
    if row ~= nil then self.owner:onTradeClick(self.side, row, -1) end
    return true
end

function TradeBox:onMouseWheel(delta)
    local most = math.max(0, #self.rows - self:visibleRows())
    self.offset = math.max(0, math.min(most, self.offset + (delta > 0 and 1 or -1)))
    return true
end

-- Window ------------------------------------------------------------------------------

local function styled(button)
    button:initialise()
    button.backgroundColor = { r = 0.055, g = 0.068, b = 0.054, a = 0.95 }
    button.borderColor = { r = 0.22, g = 0.28, b = 0.2, a = 1 }
    return button
end

function Window:createChildren()
    ISCollapsableWindow.createChildren(self)
    self:setTitle(T.get("title"))
    self:setResizable(false)
    self.backgroundColor = { r = 0.035, g = 0.042, b = 0.038, a = 0.97 }
    self.borderColor = { r = 0.34, g = 0.39, b = 0.31, a = 1 }
    local fontHeight = getTextManager():getFontHeight(UIFont.Small)
    self.fontHeight = fontHeight
    self.rowHeight = math.max(27, fontHeight + 12)
    self.headerHeight = self.height >= 600 and 122 or 74
    self.chatWidth = self.width - (self.tradeWidth or 0)
    local leaveY = self.height - self.rowHeight - 12
    local inputY = leaveY - self.rowHeight - 8
    self.statusY = inputY - fontHeight - 6

    self.transcript = ISRichTextPanel:new(16, self.headerHeight, self.chatWidth - 32, self.statusY - 6 - self.headerHeight)
    self.transcript:initialise()
    self.transcript.autosetheight = false
    self.transcript.clip = true
    self.transcript.backgroundColor = { r = 0.015, g = 0.02, b = 0.017, a = 0.85 }
    self.transcript.borderColor = { r = 0.2, g = 0.25, b = 0.2, a = 1 }
    self.transcript:addScrollBars()
    self:addChild(self.transcript)

    local sendWidth = 110
    self.entry = ISTextEntryBox:new("", 16, inputY, self.chatWidth - 32 - sendWidth - 6, self.rowHeight)
    self.entry:initialise()
    self.entry:instantiate()
    self.entry:setMaxTextLength(200)
    local window = self
    self.entry.onCommandEntered = function() window:sendEntry() end
    self.entry.onOtherKey = function(_, key)
        if Keyboard ~= nil and key == Keyboard.KEY_ESCAPE then window:close() end
    end
    self:addChild(self.entry)

    self.sendButton = styled(ISButton:new(self.chatWidth - 16 - sendWidth, inputY, sendWidth, self.rowHeight,
        T.get("send"), self, Window.sendEntry))
    self:addChild(self.sendButton)

    local leave = ISButton:new(16, leaveY, self.width - 32, self.rowHeight, T.get("leave_full"), self, Window.close)
    leave:initialise()
    self:addChild(leave)

    if (self.tradeWidth or 0) > 0 then self:createTrade(leaveY) end

    if self.shell ~= nil and self.headerHeight > 100 then
        pcall(function()
            local portrait = ISUI3DModel:new(16, 28, 82, 84)
            portrait:initialise()
            self:addChild(portrait)
            portrait:setCharacter(self.shell)
            portrait:setIsometric(false)
            portrait:setDirection(IsoDirections.S)
            portrait:setDoRandomExtAnimations(false)
            portrait:setState("idle")
            portrait:setZoom(10)
            portrait:setYOffset(-0.75)
            portrait.prerender = function(model) model.javaObject:setAnimate(false) end
            self.portrait = portrait
        end)
    end

    self.lines = {}
    for _, line in ipairs(Chat.transcripts[self.uid] or {}) do self.lines[#self.lines + 1] = line end
    self:refreshTranscript()
end

function Window:createTrade(bottom)
    local x, width = self.chatWidth, self.tradeWidth - 16
    local label = self.fontHeight + 4
    local buttonsY = bottom - 8 - 2 * (self.fontHeight + 2) - 6 - self.rowHeight
    local space = buttonsY - 8 - self.headerHeight - 2 * label - 8
    local first = math.floor(space * 0.4)

    self.tradeLabels = { { y = self.headerHeight }, { y = self.headerHeight + label + first + 8 } }
    self.playerBox = TradeBox:new(x, self.headerHeight + label, width, first, self, "player")
    self.playerBox:initialise()
    self:addChild(self.playerBox)
    self.npcBox = TradeBox:new(x, self.tradeLabels[2].y + label, width, space - first, self, "npc")
    self.npcBox:initialise()
    self:addChild(self.npcBox)

    local third = (width - 12) / 3
    self.proposeButton = styled(ISButton:new(x, buttonsY, third, self.rowHeight, T.get("trade_propose"), self, Window.proposeTrade))
    self:addChild(self.proposeButton)
    self.acceptButton = styled(ISButton:new(x + third + 6, buttonsY, third, self.rowHeight, T.get("trade_accept"), self,
        Window.acceptCounter))
    self:addChild(self.acceptButton)
    self.clearButton = styled(ISButton:new(x + 2 * (third + 6), buttonsY, third, self.rowHeight, T.get("trade_clear"), self,
        Window.clearTrade))
    self:addChild(self.clearButton)
    self.tradeStatusY = buttonsY + self.rowHeight + 6
    self:refreshTrade()
end

function Window:prerender()
    ISCollapsableWindow.prerender(self)
    local x = self.portrait ~= nil and 112 or 16
    self:drawText(plain(self.npcName or T.get("survivor")), x, 34, 0.81, 0.86, 0.67, 1, UIFont.Medium)
    self:drawText(plain(self.factionName or ""), x, 58, 0.55, 0.61, 0.54, 1, UIFont.Small)
    if self.headerHeight > 100 then
        local stance = self.stance and string.upper(T.get("stance_" .. self.stance)) or ""
        self:drawText(stance, x, 84, 0.66, 0.59, 0.39, 1, UIFont.Small)
    end
    if self.trust ~= nil then
        local mind = Dialogue.minds[self.uid]
        local goal = mind ~= nil and Dialogue.goalNow(mind, nowMs()) or (self.goal or 0)
        local mood = T.get("mood", { trust = self.trust, fear = self.fear or 0, goal = math.floor(goal + 0.5) })
        local width = getTextManager():MeasureStringX(UIFont.Small, mood)
        self:drawText(mood, self.chatWidth - 16 - width, self.headerHeight > 100 and 84 or 58, 0.66, 0.59, 0.39, 1, UIFont.Small)
    end
    if self.paused and ALifeBrain.Pause.active() then
        local note = T.get("paused_header")
        local width = getTextManager():MeasureStringX(UIFont.Small, note)
        self:drawText(note, self.chatWidth - 16 - width, 34, 0.55, 0.61, 0.54, 1, UIFont.Small)
    end
    if self.thinkingSince ~= nil then
        local dots = string.rep(".", math.floor((nowMs() - self.thinkingSince) / 400) % 4)
        self:drawText(T.get("thinking", { name = plain(self.npcName) }) .. dots, 16, self.statusY,
            0.62, 0.64, 0.58, 1, UIFont.Small)
    end
    if self.playerBox ~= nil then
        local x0 = self.chatWidth
        self:drawText(T.get("trade_title"), x0, 34, 0.81, 0.86, 0.67, 1, UIFont.Medium)
        self:drawText(T.get("trade_yours"), x0, self.tradeLabels[1].y, 0.55, 0.61, 0.54, 1, UIFont.Small)
        self:drawText(T.get("trade_theirs", { name = plain(self.npcName) }), x0, self.tradeLabels[2].y,
            0.55, 0.61, 0.54, 1, UIFont.Small)
        for index, line in ipairs(self.tradeStatus or {}) do
            self:drawText(line, x0, self.tradeStatusY + (index - 1) * (self.fontHeight + 2), 0.66, 0.59, 0.39, 1, UIFont.Small)
        end
    end
end

-- Rebuilds the transcript and scrolls to the newest line; only when lines change. (Not named
-- render: that would replace ISCollapsableWindow.render, which clears the stencil its
-- prerender sets, and every window drawn after this one would be clipped to its rectangle.)
function Window:refreshTranscript()
    self.transcript.text = table.concat(self.lines, " <LINE> <LINE> ")
    self.transcript:paginate()
    self.transcript:setYScroll(-math.max(0, self.transcript:getScrollHeight() - self.transcript.height))
end

function Window:formatLine(kind, text)
    if kind == "player" then
        return COLORS.player .. T.get("you") .. ":" .. COLORS.text .. plain(text)
    elseif kind == "npc" then
        return COLORS.npc .. plain(self.npcName or T.get("survivor")) .. ":" .. COLORS.text .. plain(text)
    elseif kind == "earlier" then
        return COLORS.earlier .. "------  " .. plain(text) .. "  ------"
    end
    return COLORS.system .. "[" .. plain(text) .. "]"
end

-- kind: "player" | "npc" | "system" | "earlier"; remember = false keeps it out of the local cache.
function Window:append(kind, text, remember)
    if text == nil or text == "" then return end
    local line = self:formatLine(kind, text)
    self.lines[#self.lines + 1] = line
    while #self.lines > Chat.settings.maxLines do table.remove(self.lines, 1) end
    if remember ~= false then
        local cache = Chat.transcripts[self.uid] or {}
        cache[#cache + 1] = line
        while #cache > Chat.settings.maxLines do table.remove(cache, 1) end
        Chat.transcripts[self.uid] = cache
    end
    if not self.closed then self:refreshTranscript() end
end

-- Earlier conversation from the sidecar replaces the local cache at the top of the transcript.
function Window:loadHistory()
    local bridge = ALifeBrain.bridge
    if bridge == nil or not bridge:isOnline() or type(bridge.features) ~= "table" or not bridge.features.history then
        return
    end
    local window = self
    bridge:request("history", { uid = self.uid, playerKey = Hooks.playerKey(self.player), limit = Chat.settings.historyLimit },
        function(ok, data)
            if not ok or type(data) ~= "table" or window.closed then return end
            window.trust, window.fear, window.goal = tonumber(data.trust), tonumber(data.fear), tonumber(data.goal)
            Dialogue.learnMood(window.uid, data, nowMs())
            local lines = {}
            local turns = type(data.turns) == "table" and data.turns or {}
            for _, turn in ipairs(turns) do
                if type(turn) == "table" and type(turn.text) == "string" then
                    local kind = (turn.speaker == "player" or turn.speaker == "npc") and turn.speaker or "system"
                    lines[#lines + 1] = window:formatLine(kind, turn.text)
                end
            end
            if #lines > 0 then lines[#lines + 1] = window:formatLine("earlier", T.get("earlier")) end
            for index = (window.cachedLines or 0) + 1, #window.lines do lines[#lines + 1] = window.lines[index] end
            window.lines = lines
            window.cachedLines = 0
            window:refreshTranscript()
        end, 8000)
end

function Window:say(key, vars)
    self:append("system", T.get(key, vars))
end

function Window:setThinking(thinking)
    self.thinkingSince = thinking and nowMs() or nil
    if not self.closed then
        self.sendButton:setEnable(not thinking)
        self:refreshTrade()
    end
end

function Window:sendText(text)
    if self.closed or self.thinkingSince ~= nil then return false end
    local player, record = self.player, Hooks.readRecord(self.uid)
    local vars = { name = plain(self.npcName) }
    local options = self.parley and { standoff = true } or nil
    local id, reason = Dialogue.ask(player, record, self.shell, text, self, self.trade, options)
    if id == nil then
        if reason == "offline" then self:say("offline")
        elseif reason == "unsupported" then self:say("unavailable")
        elseif reason == "combat" or reason == "hostile" or reason == "busy" then self:say(reason, vars)
        else self:say("closed_gone", vars) end
        return false
    end
    self:append("player", text)
    pcall(function() player:Say(text) end)
    self:setThinking(true)
    if self.parley then ALifeBrain.Parley.onPlayerLine(self.uid, nowMs()) end
    return true
end

-- In a parley the NPC speaks first: the request text is a narration for the LLM, and nothing
-- is said by the player.
Chat.PARLEY_OPENING = "(The stranger has just walked into your sights. You call out to them first.)"

function Window:sendOpening()
    if self.closed then return false end
    local id = Dialogue.ask(self.player, Hooks.readRecord(self.uid), self.shell, Chat.PARLEY_OPENING, self, self.trade,
        { standoff = true, opening = true })
    if id == nil then return false end
    self:setThinking(true)
    return true
end

function Window:sendEntry()
    if self.closed then return end
    local text = self.entry:getText() or ""
    text = string.gsub(string.gsub(text, "^%s+", ""), "%s+$", "")
    if text == "" or self.thinkingSince ~= nil then return end
    if self:sendText(text) then self.entry:setText("") end
end

-- Trade table ------------------------------------------------------------------------

function Window:refreshTrade()
    if self.playerBox == nil or self.trade == nil then return end
    local rows = {}
    for _, group in ipairs(self.trade:offeredGroups()) do
        rows[#rows + 1] = { type = group.type, label = group.name, right = "x" .. tostring(group.count), tex = group.tex,
            highlight = { 0.82, 0.68, 0.40 } }
    end
    -- What the NPC asked for and the player does not have: placeholders, nothing to click.
    for _, name in ipairs(self.trade:missingWants()) do
        rows[#rows + 1] = { label = name, right = T.get("trade_wanted_tag"), dim = true }
    end
    self.playerBox:setRows(rows, T.get("trade_yours"))

    self.npcGroups = Hooks.tradeableItems(self.shell)
    local npcRows = {}
    for _, group in ipairs(self.npcGroups) do
        local asked = self.trade:askedCount(group.type)
        local row = { type = group.type, label = group.name, tex = group.tex }
        if asked > 0 then
            row.right = tostring(asked) .. "/" .. tostring(group.count)
            row.highlight = self.trade.npcProposed and { 0.85, 0.62, 0.25 } or { 0.45, 0.75, 0.45 }
        else
            row.right = "x" .. tostring(group.count)
        end
        npcRows[#npcRows + 1] = row
    end
    self.npcBox:setRows(npcRows, T.get("trade_nothing", { name = plain(self.npcName) }))

    local idle = self.thinkingSince == nil
    self.proposeButton:setEnable(idle and not self.trade:isEmpty())
    self.acceptButton:setEnable(idle and self.trade:canAccept())
    self.clearButton:setEnable(idle and not self.trade:isEmpty())
end

-- Word-wraps text to width pixels, at most maxLines lines (the last one cut with "...").
local function wrap(text, width, maxLines)
    local lines, current = {}, ""
    local function measure(value) return getTextManager():MeasureStringX(UIFont.Small, value) end
    for word in string.gmatch(text, "%S+") do
        local candidate = current == "" and word or current .. " " .. word
        if current ~= "" and measure(candidate) > width then
            lines[#lines + 1] = current
            current = word
        else
            current = candidate
        end
    end
    if current ~= "" then lines[#lines + 1] = current end
    if #lines > maxLines then
        local last = lines[maxLines]
        while string.len(last) > 1 and measure(last .. "...") > width do last = string.sub(last, 1, -2) end
        for index = #lines, maxLines + 1, -1 do lines[index] = nil end
        lines[maxLines] = last .. "..."
    end
    return lines
end

function Window:tradeNotice(key, vars)
    self.tradeStatus = wrap(T.get(key, vars), self.tradeWidth - 16, 2)
    self.tradeStatusAt = nowMs()
end

function Window:onTradeDrop(items)
    if self.trade == nil or self.thinkingSince ~= nil then return end
    local player = self.player
    local _, refusals = self.trade:offer(items, function(item) return Hooks.playerCanTrade(player, item) end)
    local shown = {}
    for _, reason in ipairs(refusals) do
        if not shown[reason] then
            shown[reason] = true
            self:tradeNotice("trade_" .. tostring(reason))
        end
    end
    self:refreshTrade()
end

function Window:onTradeClick(side, row, delta)
    if self.trade == nil or self.thinkingSince ~= nil then return end
    if side == "player" then
        if row.type == nil then return end
        self.trade:withdraw(row.type)
    else
        for _, group in ipairs(self.npcGroups or {}) do
            if group.type == row.type then
                if not self.trade:ask(group, delta) then self:tradeNotice("trade_full") end
                break
            end
        end
    end
    self:refreshTrade()
end

function Window:proposeTrade()
    self:pruneTrade()
    if self.trade == nil or self.trade:isEmpty() then self:tradeNotice("trade_empty"); self:refreshTrade(); return end
    local text = self.entry:getText() or ""
    text = string.gsub(string.gsub(text, "^%s+", ""), "%s+$", "")
    if text == "" then text = T.get("trade_default_text") end
    if self:sendText(text) then self.entry:setText("") end
end

-- The NPC already agreed to its own counter-offer: swap without asking the LLM again. Only
-- when the player's part is on the table too (canAccept); both sides change hands at once.
function Window:acceptCounter()
    self:pruneTrade()
    if self.trade == nil or not self.trade:canAccept() or self.thinkingSince ~= nil then self:refreshTrade(); return end
    local record = Hooks.readRecord(self.uid)
    if record == nil then self:say("closed_gone", { name = plain(self.npcName) }); return end
    local outcome = Dialogue.executeTrade(self.player, record, self.shell, self.trade)
    self:append("system", T.outcome(outcome, plain(self.npcName)))
    self:refreshTrade()
end

function Window:clearTrade()
    if self.trade == nil or self.thinkingSince ~= nil then return end
    self.trade:clear()
    self:refreshTrade()
end

-- Dialogue view callbacks -------------------------------------------------------------

function Window:onReply(say, reply, outcome)
    self.thinkingSince = nil
    if type(reply) == "table" and reply.trust ~= nil then
        self.trust, self.fear, self.goal = tonumber(reply.trust), tonumber(reply.fear), tonumber(reply.goal)
    end
    self:append("npc", say)
    if type(outcome) == "table" and outcome.action == "trade" and outcome.decision == "counter" and self.trade ~= nil then
        outcome.offer, outcome.missing = self.trade:applyCounter(outcome.offer, Hooks.tradeableItems(self.shell),
            outcome.wants, Hooks.playerTradeableItems(self.player))
        outcome.unpaid = #self.trade.asked > 0 and #self.trade.offered == 0
    end
    local line = T.outcome(outcome, plain(self.npcName))
    if line ~= nil then self:append("system", line) end
    if type(outcome) == "table" and outcome.action == "leave" then self.closeAtMs = nowMs() + Chat.settings.closeDelayMs end
    if not self.closed then self:setThinking(false) end
end

function Window:onFallback(reason, alifeSaid)
    -- A plain reason where there is one (a refused line, a timeout, a busy provider).
    local key = "fallback_" .. tostring(reason)
    self:say(T.has(key) and key or "fallback", { reason = tostring(reason) })
    if type(alifeSaid) == "string" then self:append("npc", alifeSaid) end
    if not self.closed then self:setThinking(false) end
end

-- The NPC's trust just let the player close to its group, or took that back (Rapport.lua).
function Window:onRapport(change)
    self:say("rapport_" .. tostring(change), { name = plain(self.npcName) })
    local record = Hooks.readRecord(self.uid)
    if record ~= nil then self.stance = Chat.stanceOf(record, self.player) end
end

function Window:onDropped()
    self.thinkingSince = nil
    self:say("closed_gone", { name = plain(self.npcName) })
    self.closeAtMs = nowMs() + Chat.settings.closeDelayMs
end

-- Session -----------------------------------------------------------------------------

-- The keys belong to the text box only while the player works in this window: a click
-- anywhere else (inventory, Tetris grids, the world) gives them back to the game, so
-- inventory hotkeys (Tetris rotate, Tab) and movement work; a click in the window takes them.
function Window:followMouseFocus()
    local down = isMouseButtonDown(0) or isMouseButtonDown(1)
    if down and not self.mouseWasDown then
        local inside = Chat.topUiAtMouse() == self.javaObject
        pcall(function()
            if inside and not self.entry:isFocused() then self.entry:focus()
            elseif not inside and self.entry:isFocused() then self.entry:unfocus() end
        end)
    end
    self.mouseWasDown = down
end

-- Offered items stay in the player's inventory; ones moved away, dropped or put to use
-- since leave the table.
function Window:pruneTrade()
    if self.trade == nil then return end
    local player = self.player
    if self.trade:prune(function(item) return Hooks.playerCanTrade(player, item) end) > 0 then
        self:tradeNotice("trade_pruned")
    end
end

function Window:update()
    ISCollapsableWindow.update(self)
    if self.closed or not self:isVisible() then return end
    self:followMouseFocus()
    local now = nowMs()
    if self.closeAtMs ~= nil and now >= self.closeAtMs then self:close(); return end
    if self.tradeStatusAt ~= nil and now - self.tradeStatusAt > 6000 then self.tradeStatus, self.tradeStatusAt = nil, nil end
    if now < (self.nextCheckAt or 0) then return end
    self.nextCheckAt = now + Chat.settings.keepAliveMs

    local player, record = self.player, Hooks.readRecord(self.uid)
    if self.closeAtMs ~= nil then return end
    if player == nil or player:isDead() or record == nil or not Hooks.talkable(self.shell, record) then
        self:say("closed_gone", { name = plain(self.npcName) })
        self.closeAtMs = now + Chat.settings.closeDelayMs
        return
    end
    -- (A parley keeps its distance; Parley.tick ends it when the player gets away.)
    if not self.parley and not Hooks.withinReach(player, self.shell, Chat.settings.reachTiles) then
        self:say("closed_far", { name = plain(self.npcName) })
        self.closeAtMs = now + Chat.settings.closeDelayMs
        return
    end
    self.stance = Chat.stanceOf(record, player)
    -- While a reply is pending Dialogue already holds the NPC for longer.
    if Dialogue.pending[self.uid] == nil and not Hooks.inCombat(record) then
        Hooks.hold(record, self.shell, player, now, Chat.settings.holdMs)
    end
    self:pruneTrade()
    self:refreshTrade()
end

function Window:close()
    if self.closed then return end
    self.closed = true
    -- Walking out of a parley is a refusal: the crew opens fire.
    if self.parley and not self.parleyEnded then ALifeBrain.Parley.onWindowClosed(self.uid, nowMs()) end
    local record = Hooks.readRecord(self.uid)
    if record ~= nil and self.player ~= nil then
        Hooks.release(record, self.player)
        Hooks.quietPresence(record, self.player, Chat.settings.quietAfterMs)
    end
    ISCollapsableWindow.close(self)
    self:removeFromUIManager()
    if Chat.instance == self then Chat.instance = nil end
    if self.paused then ALifeBrain.Pause.release() end
end

-- Horizontal ranges { left, right } of the player's visible inventory and loot windows.
local function inventoryRanges(playerNum)
    local ranges = {}
    for _, getter in ipairs({ getPlayerInventory, getPlayerLoot }) do
        pcall(function()
            local page = getter(playerNum)
            if page ~= nil and page:isVisible() then ranges[#ranges + 1] = { page:getX(), page:getX() + page:getWidth() } end
        end)
    end
    return ranges
end

-- The window goes in the free strip beside the inventory windows that is closest to the
-- screen centre, shrinking down to minWidth to fit, so dragging items in never means
-- reaching under it; centred over them when no strip is wide enough. Returns x, width.
function Chat.placement(screenWidth, desired, minWidth, ranges)
    local margin, spacing = 12, 8
    local gaps, x = {}, margin
    table.sort(ranges, function(a, b) return a[1] < b[1] end)
    for _, range in ipairs(ranges) do
        if range[1] - spacing > x then gaps[#gaps + 1] = { x, range[1] - spacing } end
        x = math.max(x, range[2] + spacing)
    end
    if screenWidth - margin > x then gaps[#gaps + 1] = { x, screenWidth - margin } end
    local centre, best, bestX, bestWidth = screenWidth / 2, nil, nil, nil
    for _, gap in ipairs(gaps) do
        local room = gap[2] - gap[1]
        if room >= minWidth then
            local width = math.min(desired, room)
            local left = math.max(gap[1], math.min(gap[2] - width, centre - width / 2))
            local distance = math.abs(left + width / 2 - centre)
            if best == nil or distance < best then best, bestX, bestWidth = distance, left, width end
        end
    end
    if best ~= nil then return math.floor(bestX), math.floor(bestWidth) end
    local width = math.min(desired, screenWidth - 2 * margin)
    return math.floor((screenWidth - width) / 2), width
end

-- The header's stance: "trusted" for a careful group that lets the player close (Rapport.lua).
function Chat.stanceOf(record, player)
    local stance = Hooks.stance(record, player)
    if stance == "neutral" and ALifeBrain.Rapport.vouches(record, nowMs()) then return "trusted" end
    return stance
end

function Chat.open(player, row, fromKey)
    if Chat.instance ~= nil then Chat.instance:close() end
    local core = getCore()
    local screenWidth = core:getScreenWidth()
    local settings = Chat.settings
    local withTrade = screenWidth >= settings.minChatWidth + settings.tradeWidth + 24
    local desired = settings.width + (withTrade and settings.tradeWidth or 0)
    local minWidth = settings.minChatWidth + (withTrade and settings.tradeWidth or 0)
    local playerNum = 0
    pcall(function() playerNum = player:getPlayerNum() end)
    local x, width = Chat.placement(screenWidth, desired, minWidth, inventoryRanges(playerNum))
    local tradeWidth = withTrade and settings.tradeWidth or 0
    if width - tradeWidth < settings.minChatWidth then tradeWidth = 0 end
    local height = math.min(settings.height, core:getScreenHeight() - 24)
    local window = Window:new(x, (core:getScreenHeight() - height) / 2, width, height)
    window.uid, window.shell, window.player = row.uid, row.shell, player
    window.npcName, window.factionName = row.name, row.factionName
    window.stance = Chat.stanceOf(row.record, player)
    window.cachedLines = #(Chat.transcripts[row.uid] or {})
    window.tradeWidth = tradeWidth
    window.trade = Trade.new()
    window:initialise()
    window:addToUIManager()
    Chat.instance = window
    -- The game waits while the player talks (Pause.lua; single player, Mod Options).
    window.paused = ALifeBrain.Pause.hold()
    Hooks.hold(row.record, row.shell, player, nowMs(), Chat.settings.holdMs)
    window:loadHistory()
    window.entry:focus()
    if fromKey then pcall(function() window.entry:ignoreFirstInput() end) end
    return window
end

-- Parley (Parley.lua): a hostile NPC called out to the player; the window opens by itself and
-- the NPC speaks first.
function Chat.openParley(parley)
    local record = Hooks.readRecord(parley.uid)
    if record == nil then return nil end
    local info = Hooks.describe(parley.shell) or {}
    local window = Chat.open(parley.player, { uid = parley.uid, shell = parley.shell, record = record, name = info.name,
        factionName = info.factionName })
    window.parley = true
    window:say("parley_start", { name = plain(window.npcName) })
    window:sendOpening()
    return window
end

-- How the parley ended, in the window, which then closes.
function Chat.onParleyEnd(parley, outcome)
    local window = Chat.instance
    if window == nil or window.closed or window.uid ~= parley.uid then return end
    window.parleyEnded = true
    window:say("parley_" .. tostring(outcome), { name = plain(window.npcName) })
    window.closeAtMs = nowMs() + (outcome == "fight" and 1200 or Chat.settings.closeDelayMs + 1500)
end

ALifeBrain.Parley.onOpen = Chat.openParley
ALifeBrain.Parley.onEnd = Chat.onParleyEnd

-- The NPC the player is most likely addressing: in front (A-Life's 60 degree cone) first,
-- then the nearest. Hostile NPCs are skipped.
function Chat.pick(player)
    local nearby = Hooks.nearbyNpcs(player, Chat.settings.reachTiles)
    local fx, fy = nil, nil
    pcall(function()
        local forward = player:getForwardDirection()
        fx, fy = forward:getX(), forward:getY()
    end)
    local limit = math.cos(math.rad(Chat.settings.coneDegrees))
    local nearest = nil
    for _, row in ipairs(nearby) do
        if Hooks.stance(row.record, player) ~= "hostile" then
            nearest = nearest or row
            if fx ~= nil and row.distance > 0.01 then
                local dx, dy = row.shell:getX() - player:getX(), row.shell:getY() - player:getY()
                if (dx * fx + dy * fy) / row.distance >= limit then return row end
            end
        end
    end
    return nearest
end

-- Installed over A-Life's TalkInput.open: true when our window took the chat key.
function Chat.openFromKey()
    local player = getSpecificPlayer(0)
    if player == nil or player:isDead() then return false end
    if Chat.instance ~= nil and not Chat.instance.closed then
        Chat.instance:bringToTop()
        Chat.instance.entry:focus()
        pcall(function() Chat.instance.entry:ignoreFirstInput() end)
        return true
    end
    if not Dialogue.supported(ALifeBrain.bridge) then return false end
    local row = Chat.pick(player)
    if row == nil then return false end
    Chat.open(player, row, true)
    return true
end

-- Context menu (shown first in the list) ----------------------------------------------

local function addOption(context, label, ...)
    if type(context.addOptionOnTop) == "function" then return context:addOptionOnTop(label, ...) end
    return context:addOption(label, ...)
end

function Chat.fill(playerNum, context, worldobjects, test)
    if test == true or type(context) ~= "table" or type(context.addOption) ~= "function" then return end
    local player = getSpecificPlayer(playerNum)
    if player == nil or player:isDead() then return end
    local nearby = Hooks.nearbyNpcs(player, Chat.settings.reachTiles)
    if #nearby == 0 then return end
    if not Dialogue.supported(ALifeBrain.bridge) then
        local option = addOption(context, T.get("menu_offline"))
        option.notAvailable = true
        if ISToolTip ~= nil then
            local tooltip = ISToolTip:new()
            tooltip.description = T.get("menu_offline_tip")
            option.toolTip = tooltip
        end
        return
    end
    for index = math.min(#nearby, 6), 1, -1 do
        local row = nearby[index]
        if Hooks.stance(row.record, player) ~= "hostile" then
            addOption(context, T.get("menu_talk", { name = plain(row.name or T.get("survivor")) }), player, Chat.open, row)
        end
    end
end

if type(Events) == "table" and Events.OnFillWorldObjectContextMenu ~= nil then
    Events.OnFillWorldObjectContextMenu.Add(Chat.fill)
end

return Chat
