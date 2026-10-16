-- UI strings. The interface is English only (user request, 2026-10-16: it had a Turkish
-- translation too). Text.language() is still the game's language code: the LLM gets it, so an
-- NPC that speaks first (a parley) does so in the player's language; the NPCs always answer in
-- the language the player writes in. ALifeBrain.Text.forced = "TR" overrides it (debug console).

ALifeBrain = ALifeBrain or {}

local Text = { forced = nil, cached = nil }
ALifeBrain.Text = Text

Text.strings = {
    EN = {
        title = "A-LIFE BRAIN  /  CONVERSATION",
        menu_talk = "A-Life Brain: talk to {name}",
        menu_offline = "A-Life Brain: sidecar not running",
        menu_offline_tip = "Start sidecar\\run-sidecar.cmd, then try again.",
        survivor = "Survivor",
        you = "You",
        send = "Send",
        leave = "Leave",
        leave_full = "[Leave]  See you around.",
        thinking = "{name} is thinking",
        earlier = "earlier conversation",
        mood = "Trust {trust}   Fear {fear}   Drive {goal}",
        option_control = "Trained policy chooses NPC behaviour",
        option_pause = "Pause the game while talking",
        option_pause_tip = "Single player: while the conversation window is open the game stands still, so the dead and fights wait. It goes on at its old speed when the window closes. The inventory key does not work while the game is paused: open the inventory before talking if you want to trade.",
        paused_header = "GAME PAUSED",
        option_keep = "Keep NPCs you meet (never deleted)",
        option_keep_tip = "An NPC that comes within 10 tiles of you is kept with its group: A-Life writes it into the save and never deletes it as an unvisited NPC, even after you walk away. Off: only new meetings stop being kept. A-Life saves at most its \"Saved group limit\" sandbox option (default 20) of such groups.",
        keep_cap = "A-Life Brain: {groups} groups to keep, A-Life saves {cap}. Raise \"Saved group limit\" in A-Life's sandbox options.",
        option_control_tip = "Off: A-Life decides alone (the policy only watches). On: the RL policy picks among A-Life's own behaviours, steered by the trust, fear and drive conversations leave. Player orders, conversations, robberies and fights with players always stay with A-Life.",
        stance_friendly = "Friendly", stance_neutral = "Neutral", stance_careful = "Careful", stance_hostile = "Hostile",
        stance_trusted = "Trusts you",
        rapport_granted = "{name} trusts you now: their group lets you come close.",
        rapport_withdrawn = "{name} no longer trusts you: their group wants you to keep your distance again.",
        offline = "No connection to the A-Life Brain sidecar.",
        unavailable = "The sidecar has no AI provider ready.",
        busy = "{name} is still answering.",
        combat = "{name} is fighting. Talk later.",
        hostile = "{name} is hostile and will not talk.",
        fallback = "No answer from the AI ({reason}); A-Life answered instead.",
        fallback_http_400 = "The AI would not answer that line. Try saying it another way; A-Life answered instead.",
        fallback_timeout = "The AI took too long to answer; say it again. A-Life answered instead.",
        fallback_rate_limited = "The AI is busy right now; wait a moment. A-Life answered instead.",
        closed_far = "{name} is too far away. Conversation ended.",
        closed_gone = "{name} can no longer talk. Conversation ended.",
        item_water = "water", item_food = "food", item_medicine = "medicine",
        gave = "{name} gave you: {item} (added to your inventory)",
        give_no_item = "{name} has no {item} to give.",
        give_too_far = "Too far away to hand anything over.",
        give_limit = "{name} has given you enough for now.",
        give_refused = "{name} could not hand it over.",
        give_combat = "{name} is in the middle of a fight. Try again when it is over.",
        follow_ok = "{name} is following you for {minutes} minutes.",
        follow_low_trust = "{name} does not trust you enough to follow yet.",
        follow_refused = "{name} cannot follow you right now.",
        stay_ok = "{name} is waiting here.",
        stay_refused = "{name} cannot wait here right now.",
        left = "{name} ended the conversation.",
        trade_title = "TRADE",
        trade_yours = "You offer (drag items here)",
        trade_theirs = "{name} has (click to ask, right-click for less)",
        trade_propose = "Offer",
        trade_accept = "Accept",
        trade_clear = "Clear",
        trade_default_text = "What do you say to this trade?",
        trade_counter = "{name} offers instead: {items}. Press Accept to take the deal.",
        trade_more = "{name} wants more for that.",
        trade_rejected = "{name} turned the trade down.",
        trade_done = "Trade done: you got {given} and gave {received}.",
        trade_got = "{name} gave you: {given} (added to your inventory)",
        trade_gift = "{name} accepted your gift: {received}.",
        trade_changed = "The trade did not happen: the items on the table changed.",
        trade_too_far = "Too far away to trade.",
        trade_refused = "{name} cannot trade right now.",
        trade_combat = "{name} is in the middle of a fight. Try again when it is over.",
        trade_empty = "The trade table is empty.",
        trade_not_yours = "Only items in your own inventory can be offered.",
        trade_equipped = "Take it off first: worn, held or attached items cannot be traded.",
        trade_full = "The table holds at most 10 items per side.",
        trade_not_empty = "Empty it first: bags with items inside cannot be traded.",
        trade_favorite = "Favourite items cannot be traded; unmark it first.",
        trade_pruned = "Taken off the table: no longer in your inventory, or now in use.",
        trade_deal = "{name} proposes {items} for your {wants}. Both are on the table; Accept swaps them at the same moment.",
        trade_wants_only = "{name} asks for your {wants}. It is on the table; Accept hands it over.",
        trade_counter_unpaid = "{name} puts {items} on the table but wants something in return: put it down and press Offer.",
        trade_wants_missing = "You do not have: {wants}.",
        trade_unpaid = "{name} wants something in return: put it on the table and offer again.",
        trade_open_window = "{name} offers a trade: {items}. Open the conversation window to trade.",
        trade_wanted_tag = "wanted",
        trade_nothing = "{name}: nothing to trade.",
        parley_start = "{name} has you covered. Talk your way out, pay (walk up to hand it over), or fight. Closing this window means a fight.",
        parley_fight = "{name} opens fire!",
        parley_paid = "{name} takes the tribute and lets you go.",
        parley_sent_away = "{name} lets you go. Get moving.",
        parley_got_away = "You got away from {name}.",
        parley_gone = "{name} is gone.",
    },
}

local function join(names)
    local out = {}
    for _, name in ipairs(type(names) == "table" and names or {}) do out[#out + 1] = tostring(name) end
    return table.concat(out, ", ")
end

-- The game's language code ("EN", "TR", "DE" ...), for the LLM.
function Text.language()
    if Text.forced ~= nil then return Text.forced end
    if Text.cached ~= nil then return Text.cached end
    local code = "EN"
    pcall(function()
        local language = Translator.getLanguage()
        local name = language ~= nil and type(language.name) == "function" and language:name() or tostring(language)
        if name ~= nil and tostring(name) ~= "" then code = string.upper(tostring(name)) end
    end)
    Text.cached = code
    return Text.cached
end

-- Text.get("gave", { name = "Henry", item = "Water Bottle" })
function Text.has(key)
    return Text.strings.EN[key] ~= nil
end

function Text.get(key, vars)
    local template = Text.strings.EN[key] or key
    return (string.gsub(template, "{(%w+)}", function(name)
        local value = type(vars) == "table" and vars[name] or nil
        return value ~= nil and tostring(value) or ""
    end))
end

-- Line shown in the chat window for what the game did after an NPC's intent.
function Text.outcome(outcome, name)
    if type(outcome) ~= "table" then return nil end
    local item = outcome.item ~= nil and Text.get("item_" .. tostring(outcome.item)) or ""
    local vars = { name = name, item = outcome.label or item, minutes = outcome.minutes }
    if outcome.action == "give" then
        if outcome.ok then return Text.get("gave", vars) end
        vars.item = item
        return Text.get("give_" .. tostring(outcome.reason or "refused"), vars)
    elseif outcome.action == "follow" then
        return Text.get(outcome.ok and "follow_ok" or ("follow_" .. tostring(outcome.reason or "refused")), vars)
    elseif outcome.action == "stay" then
        return Text.get(outcome.ok and "stay_ok" or "stay_refused", vars)
    elseif outcome.action == "leave" then
        return Text.get("left", vars)
    elseif outcome.action == "trade" then
        if outcome.decision == "counter" then
            local items, wants = join(outcome.offer), join(outcome.wants)
            local dealVars = { name = name, items = items, wants = wants }
            if outcome.noTable then return items ~= "" and Text.get("trade_open_window", dealVars) or nil end
            if items == "" and wants == "" then return Text.get("trade_more", vars) end
            local line
            if items ~= "" and wants ~= "" then line = Text.get("trade_deal", dealVars)
            elseif wants ~= "" then line = Text.get("trade_wants_only", dealVars)
            elseif outcome.unpaid then line = Text.get("trade_counter_unpaid", dealVars)
            else line = Text.get("trade_counter", dealVars) end
            local missing = join(outcome.missing)
            if missing ~= "" then line = line .. " " .. Text.get("trade_wants_missing", { wants = missing }) end
            return line
        elseif outcome.decision == "reject" then
            return Text.get("trade_rejected", vars)
        elseif outcome.ok then
            local given, received = join(outcome.given), join(outcome.received)
            local tradeVars = { name = name, given = given, received = received }
            if given ~= "" and received ~= "" then return Text.get("trade_done", tradeVars) end
            if given ~= "" then return Text.get("trade_got", tradeVars) end
            return Text.get("trade_gift", tradeVars)
        end
        return Text.get("trade_" .. tostring(outcome.reason or "refused"), vars)
    end
    return nil
end

return Text
