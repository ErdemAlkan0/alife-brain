import json
import unittest

from alifebrain_sidecar.dialogue import (
    MAX_SAY,
    STRANGER_SAYS,
    BadRequest,
    InvalidReply,
    build_messages,
    parse_reply,
    parse_request,
)
from alifebrain_sidecar.memory import Memory


def request_data(**overrides):
    data = {
        "text": "Hey, you got any water?",
        "player": {"key": "sp:0", "weapon": "hammer"},
        "npc": {"uid": "palife:1:7", "name": "Hobbs Rifleman", "factionId": "alife_hobbs",
                "factionName": "Hobbs Family", "groupId": "g1", "roleLabel": "Militia - Rifleman",
                "temperament": "seasoned", "sex": "m", "behaviorState": "idle", "wounds": 1},
        "stance": "careful",
        "facts": {"player_armed": True, "recent_zombie_contact": True, "junk": "x"},
        "world": {"town": "Muldraugh", "hour": 14, "day": 2},
    }
    data.update(overrides)
    return data


class ParseRequestTests(unittest.TestCase):
    def test_reads_the_game_request(self):
        request = parse_request(request_data())
        self.assertEqual(request.npc.uid, "palife:1:7")
        self.assertEqual(request.npc.faction_name, "Hobbs Family")
        self.assertEqual(request.player_key, "sp:0")
        self.assertEqual(request.stance, "careful")
        self.assertTrue(request.wounded)
        self.assertEqual(request.facts, {"player_armed": True, "recent_zombie_contact": True})

    def test_cleans_and_limits_player_text(self):
        request = parse_request(request_data(text="  hello\n\tthere  " + "x" * 500))
        self.assertTrue(request.text.startswith("hello there"))
        self.assertLessEqual(len(request.text), 300)

    def test_unknown_stance_becomes_neutral(self):
        self.assertEqual(parse_request(request_data(stance="best_friends")).stance, "neutral")

    def test_rejects_unusable_requests(self):
        for data in [None, [], request_data(text=""), request_data(npc={}), request_data(player={"key": ""})]:
            with self.subTest(data=str(data)[:60]):
                with self.assertRaises(BadRequest):
                    parse_request(data)


class BuildMessagesTests(unittest.TestCase):
    def test_prompt_contains_persona_situation_memories_and_history(self):
        request = parse_request(request_data())
        memories = [Memory("personal", 1, "hit_by_player", "The stranger hit me with a hammer.", 7)]
        history = [("player", "Hello?"), ("npc", "Back off.")]
        system, user = build_messages(request, memories=memories, history=history, trust=-10, fear=8)
        self.assertEqual(system["role"], "system")
        for expected in ["Hobbs Rifleman", "Hobbs Family", "Militia - Rifleman", "wary", "-10", "wounded",
                         "holding a weapon (hammer)", "Muldraugh", "day 3", "hit me with a hammer",
                         "language the stranger uses", '"intent"']:
            self.assertIn(expected, system["content"])
        self.assertIn("The stranger: Hello?", user["content"])
        self.assertIn("You: Back off.", user["content"])
        self.assertTrue(user["content"].endswith(f'{STRANGER_SAYS} "Hey, you got any water?"'))

    def test_prompt_lists_inventory_and_real_actions(self):
        request = parse_request(request_data(npc={"uid": "u", "inventory": {"water": 1, "food": 0, "medicine": 3,
                                                                            "rifle": 9}, "following": True}))
        self.assertEqual(request.inventory, {"water": 1, "food": 0, "medicine": 3})
        system, _ = build_messages(request, memories=[], history=[("system", "Henry handed over Water Bottle.")],
                                   trust=0, fear=0)
        self.assertIn("You carry and could hand over: 1 water bottle, 3 medical items.", system["content"])
        named = parse_request(request_data(npc={"uid": "u", "inventory": {"medicine": 2},
                                                "inventoryItems": {"medicine": ["Bandaj", "Ağrı Kesici", 7]}}))
        self.assertEqual(named.inventory_items, {"medicine": ["Bandaj", "Ağrı Kesici"]})
        named_system, _ = build_messages(named, memories=[], history=[], trust=0, fear=0)
        self.assertIn("2 medical items (Bandaj, Ağrı Kesici)", named_system["content"])
        self.assertIn("You are a survivor in Knox County", named_system["content"], "no name, no repetition")
        self.assertIn("You are travelling with the stranger.", system["content"])
        self.assertIn("Never claim you handed something over", system["content"])
        _, user = build_messages(request, memories=[], history=[("system", "Henry handed over Water Bottle.")],
                                 trust=0, fear=0)
        self.assertIn("(What actually happened) Henry handed over Water Bottle.", user["content"])

    def test_a_careful_npc_that_trusts_the_stranger_lets_them_close(self):
        request = parse_request(request_data(stance="neutral", vouched=True))
        self.assertTrue(request.vouched)
        system, _ = build_messages(request, memories=[], history=[], trust=7, fear=0)
        self.assertIn("they earned your trust", system["content"])
        self.assertIn("do not tell them to keep away", system["content"])
        self.assertNotIn("neither a friend nor an enemy", system["content"])
        self.assertFalse(parse_request(request_data(vouched="yes")).vouched)
        standoff = parse_request(request_data(stance="hostile", vouched=True, standoff={}))
        system, _ = build_messages(standoff, memories=[], history=[], trust=7, fear=0)
        self.assertIn("the stranger is an enemy", system["content"], "a standoff stays a standoff")

    def test_minimal_request_still_builds(self):
        request = parse_request({"text": "hi", "player": {"key": "sp:0"}, "npc": {"uid": "u"}})
        system, user = build_messages(request, memories=[], history=[], trust=0, fear=0)
        self.assertIn("a survivor", system["content"])
        self.assertNotIn("What you remember", system["content"])


class ParseReplyTests(unittest.TestCase):
    def test_valid_reply(self):
        reply = parse_reply(json.dumps({"say": "Keep your distance.", "memory_note": "Stranger asked for water.",
                                        "trust_delta": 2, "fear_delta": -1, "intent": "warn"}))
        self.assertEqual(reply.say, "Keep your distance.")
        self.assertEqual(reply.intent, "warn")
        self.assertEqual((reply.trust_delta, reply.fear_delta), (2, -1))
        self.assertEqual(reply.goal_delta, 0, "missing goal_delta is 0")

    def test_goal_delta_is_clamped_wider_than_moods(self):
        reply = parse_reply('{"say": "Let us go.", "trust_delta": 40, "goal_delta": 90}')
        self.assertEqual((reply.trust_delta, reply.goal_delta), (10, 25))
        self.assertEqual(parse_reply('{"say": "Hide.", "goal_delta": "-12"}').goal_delta, -12)

    def test_prompt_states_the_drive(self):
        request = parse_request(request_data())
        system, _ = build_messages(request, memories=[], history=[], trust=0, fear=0, goal=-40)
        self.assertIn("Your drive right now is -40", system["content"])
        self.assertIn("goal_delta", system["content"])
        self.assertIn("Blame the stranger only for what your memories or this conversation show", system["content"])
        self.assertIn("Never ask again for proof you already asked for", system["content"])
        self.assertIn("+3 to +6 when they help you", system["content"])

    def test_extracts_json_from_chatty_or_fenced_output(self):
        for text in ['Sure! {"say": "Hi."} Hope that helps',
                     '```json\n{"say": "Hi."}\n```']:
            with self.subTest(text=text):
                self.assertEqual(parse_reply(text).say, "Hi.")

    def test_give_needs_a_known_item(self):
        give = parse_reply('{"say": "Here.", "intent": "give", "item": "Water"}')
        self.assertEqual((give.intent, give.item), ("give", "water"))
        self.assertEqual(parse_reply('{"say": "Here.", "intent": "give", "item": "rifle"}').intent, "none")
        self.assertEqual(parse_reply('{"say": "Here.", "intent": "give"}').intent, "none")
        follow = parse_reply('{"say": "Lead on.", "intent": "follow", "item": "water"}')
        self.assertEqual((follow.intent, follow.item), ("follow", None), "item only travels with give")

    def test_item_names_and_aliases_map_to_categories(self):
        request = parse_request(request_data(npc={"uid": "u", "inventory": {"food": 1, "medicine": 2},
                                                  "inventoryItems": {"food": ["Cips"], "medicine": ["Bandaj"]}}))
        cases = {"Cips": "food", "cips": "food", "Bandaj": "medicine", "bandages": "medicine",
                 "medkit": "medicine", "a bottle of water": "water", "food": "food"}
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                reply = parse_reply(json.dumps({"say": "Here.", "intent": "give", "item": raw}), request)
                self.assertEqual((reply.intent, reply.item), ("give", expected))
        self.assertEqual(parse_reply('{"say": "Here.", "intent": "give", "item": "supplies"}', request).intent,
                         "none", "'su' inside another word is not water; two kinds carried, so no guess")

    def test_missing_item_uses_the_only_kind_carried(self):
        request = parse_request(request_data(npc={"uid": "u", "inventory": {"water": 0, "medicine": 1}}))
        reply = parse_reply('{"say": "Take this.", "intent": "give"}', request)
        self.assertEqual((reply.intent, reply.item), ("give", "medicine"))

    def trade_request(self, table=True):
        npc = {"uid": "u", "tradeable": [{"name": "Konserve Fasulye", "count": 2}, {"name": "Çekiç"}, {"name": 5}]}
        data = request_data(npc=npc)
        if table:
            data["trade"] = {"playerOffer": [{"name": "Bandaj", "count": 2}], "npcSide": [{"name": "Çekiç"}]}
        return parse_request(data)

    def test_trade_request_and_prompt(self):
        request = self.trade_request()
        self.assertEqual([line.text() for line in request.tradeable], ["2x Konserve Fasulye", "Çekiç"])
        self.assertTrue(request.trade_open)
        system, _ = build_messages(request, memories=[], history=[], trust=0, fear=0)
        self.assertIn("Everything you carry that you could trade: 2x Konserve Fasulye, Çekiç.", system["content"])
        self.assertIn("the stranger puts down 2x Bandaj; the stranger asks you for Çekiç.", system["content"])
        gift = parse_request(dict(request_data(), trade={"playerOffer": [{"name": "Bandaj"}], "npcSide": []}))
        system, _ = build_messages(gift, memories=[], history=[], trust=0, fear=0)
        self.assertIn("asks you for nothing (it would be a gift to you)", system["content"])

    def test_trade_decisions(self):
        request = self.trade_request()
        accept = parse_reply('{"say": "Deal.", "trade": {"decision": "Accept"}}', request)
        self.assertEqual((accept.intent, accept.trade_decision, accept.trade_offer), ("trade", "accept", ()))
        counter = parse_reply('{"say": "Not the hammer.", "intent": "trade", "trade": {"decision": "counter", '
                              '"npc_offer": ["konserve", "a rifle", "Konserve Fasulye"]}}', request)
        self.assertEqual((counter.trade_decision, counter.trade_offer), ("counter", ("Konserve Fasulye",)))
        reject = parse_reply('{"say": "No.", "trade": {"decision": "no deal"}}', request)
        self.assertIsNone(reject.trade_decision, "unknown words are not decisions")
        self.assertEqual(parse_reply('{"say": "No.", "trade": {"decision": "decline"}}', request).trade_decision, "reject")
        self.assertIsNone(parse_reply('{"say": "Hi.", "trade": null}', request).trade_decision)

    def test_trade_without_a_table(self):
        request = self.trade_request(table=False)
        self.assertIsNone(parse_reply('{"say": "Deal.", "trade": {"decision": "accept"}}', request).trade_decision,
                          "nothing to accept")
        offer = parse_reply('{"say": "Want beans?", "trade": {"decision": "accept", "npc_offer": ["Konserve Fasulye"]}}',
                            request)
        self.assertEqual((offer.trade_decision, offer.trade_offer), ("counter", ("Konserve Fasulye",)),
                         "an offer without a table opens one")

    def deal_request(self, text, window=True):
        """window: the conversation window is open, so the game lists the stranger's things."""
        player = {"key": "sp:0"}
        if window:
            player["tradeable"] = [{"name": "Bandaj", "count": 2}, {"name": "Çivi"}]
        return parse_request(request_data(
            text=text, player=player,
            npc={"uid": "u", "inventory": {"water": 1, "food": 1},
                 "inventoryItems": {"water": ["Su Şişesi"], "food": ["Konserve Fasulye"]},
                 "tradeable": [{"name": "Su Şişesi"}, {"name": "Konserve Fasulye"}]}))

    def test_npc_wants_the_strangers_things(self):
        request = self.deal_request("Ne istersin?")
        self.assertEqual([line.text() for line in request.player_tradeable], ["2x Bandaj", "Çivi"])
        system, _ = build_messages(request, memories=[], history=[], trust=0, fear=0)
        self.assertIn("The stranger carries these things you could ask for in a trade: 2x Bandaj, Çivi.",
                      system["content"])
        self.assertIn("Never hand anything over on a promise", system["content"])
        reply = parse_reply('{"say": "Su, bandaja.", "trade": {"decision": "counter", "npc_offer": ["Su Şişesi"], '
                            '"npc_wants": ["bandaj", "Tüfek"]}}', request)
        self.assertEqual((reply.intent, reply.trade_decision, reply.trade_offer, reply.trade_wants),
                         ("trade", "counter", ("Su Şişesi",), ("Bandaj",)), "only things the stranger really has")
        no_table = parse_reply('{"say": "Bandaj ver.", "trade": {"decision": "counter", "npc_offer": ["Su Şişesi"], '
                               '"npc_wants": ["Bandaj"]}}', self.deal_request("Ne istersin?", window=False))
        self.assertEqual(no_table.trade_wants, (), "wants need the window to be filled in")

    def test_accepting_an_unpaid_table_becomes_a_counter(self):
        request = parse_request(request_data(
            text="Fasulyeni ver.", player={"key": "sp:0", "tradeable": [{"name": "Bandaj"}]},
            npc={"uid": "u", "tradeable": [{"name": "Konserve Fasulye", "count": 2}]},
            trade={"playerOffer": [], "npcSide": [{"name": "Konserve Fasulye", "count": 2}]}))
        reply = parse_reply('{"say": "Bandajın karşılığında.", "trade": {"decision": "accept", '
                            '"npc_wants": ["Bandaj"]}}', request)
        self.assertEqual((reply.trade_decision, reply.trade_offer, reply.trade_wants),
                         ("counter", ("Konserve Fasulye",), ("Bandaj",)))
        plain = parse_reply('{"say": "Al.", "trade": {"decision": "accept"}}', request)
        self.assertEqual(plain.trade_decision, "accept", "the game refuses an unpaid swap itself")

    def test_a_give_that_is_half_a_deal_goes_on_the_table(self):
        give = '{"say": "Tamam, al.", "intent": "give", "item": "water"}'
        for text in ("Suyu ver, sana bandajımı vereyim.", "Suya karşılık bandaj?", "Give me water, I'll pay you back"):
            with self.subTest(text=text):
                reply = parse_reply(give, self.deal_request(text))
                self.assertEqual((reply.intent, reply.item, reply.trade_decision, reply.trade_offer),
                                 ("trade", None, "counter", ("Su Şişesi",)))
                self.assertTrue(reply.deal_guard)
        self.assertEqual(parse_reply(give, self.deal_request("Suyu ver, sana bandajımı vereyim.")).trade_wants,
                         ("Bandaj",), "what the stranger promised goes on their side")
        self.assertEqual(parse_reply(give, self.deal_request("Suya karşılık bandaj?", window=False)).trade_wants, ())
        gift = parse_reply(give, self.deal_request("Çok susadım, biraz su var mı?"))
        self.assertEqual((gift.intent, gift.item, gift.deal_guard), ("give", "water", False))
        npc_promise = parse_reply('{"say": "Sana su vereceğim, al.", "intent": "give", "item": "water"}',
                                  self.deal_request("Su?"))
        self.assertEqual(npc_promise.intent, "give", "the NPC promising to give is still a gift")
        unnamed = parse_request(request_data(text="Ilaç ver, karşılığında para veririm.",
                                             npc={"uid": "u", "inventory": {"medicine": 1}}))
        reply = parse_reply('{"say": "Al.", "intent": "give", "item": "medicine"}', unnamed)
        self.assertEqual((reply.intent, reply.trade_decision), ("none", None), "cannot be put on the table: no gift")

    def test_a_standoff_opening(self):
        data = request_data(text="(The stranger has just walked into your sights. You call out to them first.)",
                            stance="hostile", standoff={"opening": True},
                            world={"town": "Muldraugh", "hour": 22, "language": "TR"},
                            player={"key": "sp:0", "tradeable": [{"name": "Konserve Fasulye", "count": 3}]})
        request = parse_request(data)
        self.assertEqual((request.standoff, request.opening, request.language, request.stance),
                         (True, True, "TR", "hostile"))
        system, user = build_messages(request, memories=[], history=[], trust=0, fear=0)
        self.assertIn("STANDOFF: you and your people are hostile to the stranger", system["content"])
        self.assertIn("the stranger is an enemy", system["content"])
        self.assertTrue(user["content"].endswith("You call out to them first.) Speak Turkish."))
        self.assertNotIn(STRANGER_SAYS, user["content"], "nothing from the stranger yet")
        demand = parse_reply('{"say": "Fasulyeleri bırak.", "intent": "rob", "trade": {"decision": "counter", '
                             '"npc_offer": [], "npc_wants": ["Konserve Fasulye"]}}', request)
        self.assertEqual((demand.intent, demand.trade_decision, demand.trade_offer, demand.trade_wants),
                         ("rob", "counter", (), ("Konserve Fasulye",)),
                         "tribute: their things, nothing back (the game acts on the trade whatever the intent)")
        later = parse_request(dict(data, text="Tamam, alın.", standoff={}))
        self.assertEqual((later.standoff, later.opening), (True, False))
        _, user = build_messages(later, memories=[], history=[], trust=0, fear=0)
        self.assertIn(f'{STRANGER_SAYS} "Tamam, alın."', user["content"])
        self.assertFalse(parse_request(request_data()).standoff)

    def test_intent_variants(self):
        for raw, expected in {"hand_over": "give", "Give Item": "give", "drop": "give", "wait": "stay",
                              "join": "follow", "dance": "none"}.items():
            with self.subTest(raw=raw):
                reply = parse_reply(json.dumps({"say": "Ok.", "intent": raw, "item": "water"}))
                self.assertEqual(reply.intent, expected)
                self.assertEqual(reply.raw_intent, raw)

    def test_clamps_and_whitelists(self):
        reply = parse_reply(json.dumps({"say": "Fine.", "trust_delta": 99, "fear_delta": "-50",
                                        "intent": "launch_nukes"}))
        self.assertEqual(reply.trust_delta, 10)
        self.assertEqual(reply.fear_delta, -10)
        self.assertEqual(reply.intent, "none")

    def test_defaults_for_missing_optional_fields(self):
        reply = parse_reply('{"say": "Hm."}')
        self.assertEqual((reply.memory_note, reply.trust_delta, reply.fear_delta, reply.intent), ("", 0, 0, "none"))

    def test_shortens_long_speech_at_a_sentence(self):
        long = "I saw them first. " * 30
        reply = parse_reply(json.dumps({"say": long}))
        self.assertLessEqual(len(reply.say), MAX_SAY + 3)
        self.assertTrue(reply.say.endswith("."))

    def test_strips_control_characters_and_quotes(self):
        self.assertEqual(parse_reply('{"say": "\\"Go\\nnow.\\""}').say, "Go now.")

    def test_rejects_unusable_output(self):
        for text in ["", "no json here", '{"say": ""}', '{"say": 5}', "[1, 2]", '{"text": "hi"}']:
            with self.subTest(text=text):
                with self.assertRaises(InvalidReply):
                    parse_reply(text)


if __name__ == "__main__":
    unittest.main()
