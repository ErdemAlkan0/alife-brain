-- UI strings in English and Turkish. Picks the game's language when it is one of these,
-- English otherwise. ALifeBrain.Text.forced = "TR" overrides (debug console).

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
        mood = "Trust {trust}   Fear {fear}",
        stance_friendly = "Friendly", stance_neutral = "Neutral", stance_careful = "Careful", stance_hostile = "Hostile",
        offline = "No connection to the A-Life Brain sidecar.",
        unavailable = "The sidecar has no AI provider ready.",
        busy = "{name} is still answering.",
        combat = "{name} is fighting. Talk later.",
        hostile = "{name} is hostile and will not talk.",
        fallback = "No answer from the AI ({reason}); A-Life answered instead.",
        closed_far = "{name} is too far away. Conversation ended.",
        closed_gone = "{name} can no longer talk. Conversation ended.",
        item_water = "water", item_food = "food", item_medicine = "medicine",
        gave = "{name} gave you: {item} (added to your inventory)",
        give_no_item = "{name} has no {item} to give.",
        give_too_far = "Too far away to hand anything over.",
        give_limit = "{name} has given you enough for now.",
        give_refused = "{name} could not hand it over.",
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
    },
    TR = {
        title = "A-LIFE BRAIN  /  SOHBET",
        menu_talk = "A-Life Brain: {name} ile konuş",
        menu_offline = "A-Life Brain: sidecar çalışmıyor",
        menu_offline_tip = "sidecar\\run-sidecar.cmd dosyasını başlatıp tekrar dene.",
        survivor = "Hayatta kalan",
        you = "Sen",
        send = "Gönder",
        leave = "Ayrıl",
        leave_full = "[Ayrıl]  Sonra görüşürüz.",
        thinking = "{name} düşünüyor",
        earlier = "önceki konuşmalar",
        mood = "Güven {trust}   Korku {fear}",
        stance_friendly = "Dost", stance_neutral = "Tarafsız", stance_careful = "Temkinli", stance_hostile = "Düşman",
        offline = "A-Life Brain sidecar'ına bağlantı yok.",
        unavailable = "Sidecar'da hazır bir yapay zekâ sağlayıcısı yok.",
        busy = "{name} hâlâ cevap veriyor.",
        combat = "{name} çatışmada. Sonra konuş.",
        hostile = "{name} sana düşman, konuşmuyor.",
        fallback = "Yapay zekâdan cevap gelmedi ({reason}); A-Life kendi cevabını verdi.",
        closed_far = "{name} çok uzakta. Konuşma bitti.",
        closed_gone = "{name} artık konuşamıyor. Konuşma bitti.",
        item_water = "su", item_food = "yiyecek", item_medicine = "ilaç",
        gave = "{name} sana verdi: {item} (envanterine eklendi)",
        give_no_item = "{name}: verecek {item} yok.",
        give_too_far = "Bir şey vermek için çok uzaktasın.",
        give_limit = "{name} şimdilik yeterince verdi.",
        give_refused = "{name} veremedi.",
        follow_ok = "{name} {minutes} dakika boyunca seni takip edecek.",
        follow_low_trust = "{name} seni takip edecek kadar güvenmiyor.",
        follow_refused = "{name} şu an seni takip edemiyor.",
        stay_ok = "{name} burada bekliyor.",
        stay_refused = "{name} şu an burada bekleyemiyor.",
        left = "{name} konuşmayı bitirdi.",
        trade_title = "TAKAS",
        trade_yours = "Senin teklifin (eşyaları buraya sürükle)",
        trade_theirs = "{name} (istediğine tıkla, sağ tık azaltır)",
        trade_propose = "Teklif et",
        trade_accept = "Kabul et",
        trade_clear = "Temizle",
        trade_default_text = "Bu takasa ne dersin?",
        trade_counter = "{name} bunun yerine şunu öneriyor: {items}. Kabul etmek için 'Kabul et'e bas.",
        trade_more = "{name} bunun için daha fazlasını istiyor.",
        trade_rejected = "{name} takası reddetti.",
        trade_done = "Takas tamam: {given} aldın, {received} verdin.",
        trade_got = "{name} sana verdi: {given} (envanterine eklendi)",
        trade_gift = "{name} hediyeni kabul etti: {received}.",
        trade_changed = "Takas olmadı: masadaki eşyalar değişti.",
        trade_too_far = "Takas için çok uzaktasın.",
        trade_refused = "{name} şu an takas yapamıyor.",
        trade_empty = "Takas masası boş.",
        trade_not_yours = "Yalnızca kendi envanterindeki eşyaları teklif edebilirsin.",
        trade_equipped = "Önce çıkar: giyilen, elde tutulan ya da takılı eşyalar takas edilemez.",
        trade_full = "Masaya her taraftan en fazla 10 eşya konabilir.",
        trade_not_empty = "Önce boşalt: içinde eşya olan çantalar takas edilemez.",
        trade_favorite = "Favori eşyalar takas edilemez; önce favoriden çıkar.",
        trade_pruned = "Masadan kaldırıldı: artık envanterinde değil ya da kullanımda.",
        trade_deal = "{name} öneriyor: {items} karşılığında senin {wants}. İkisi de masada; 'Kabul et' deyince aynı anda değişilir.",
        trade_wants_only = "{name} senden {wants} istiyor. Masada; 'Kabul et' deyince verilir.",
        trade_counter_unpaid = "{name} masaya {items} koydu ama karşılığında bir şey istiyor: koy ve 'Teklif et'e bas.",
        trade_wants_missing = "Sende yok: {wants}.",
        trade_unpaid = "{name} karşılığında bir şey istiyor: masaya bir şey koy ve yeniden teklif et.",
        trade_open_window = "{name} takas öneriyor: {items}. Takas için sohbet penceresini aç.",
        trade_wanted_tag = "istenen",
        trade_nothing = "{name}: takas edecek bir şey yok.",
    },
}

local function join(names)
    local out = {}
    for _, name in ipairs(type(names) == "table" and names or {}) do out[#out + 1] = tostring(name) end
    return table.concat(out, ", ")
end

function Text.language()
    if Text.forced ~= nil then return Text.forced end
    if Text.cached ~= nil then return Text.cached end
    local code = "EN"
    pcall(function()
        local language = Translator.getLanguage()
        local name = language ~= nil and type(language.name) == "function" and language:name() or tostring(language)
        if name ~= nil then code = string.upper(tostring(name)) end
    end)
    Text.cached = Text.strings[code] ~= nil and code or "EN"
    return Text.cached
end

-- Text.get("gave", { name = "Henry", item = "Water Bottle" })
function Text.get(key, vars)
    local strings = Text.strings[Text.language()] or Text.strings.EN
    local template = strings[key] or Text.strings.EN[key] or key
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
