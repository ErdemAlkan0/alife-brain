import unittest

from alifebrain_sidecar.experience import apply_event, weapon_name
from alifebrain_sidecar.memory import GOAL_HALF_LIFE_MS, MemoryStore, Npc

DAY_MS = 24 * 3_600_000


class MemoryStoreTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore(":memory:")
        self.npc = Npc(uid="u1", name="Hobbs Rifleman", faction_id="hobbs", group_id="g1")
        self.store.upsert_npc(self.npc, 1000)

    def tearDown(self):
        self.store.close()

    def test_upsert_keeps_known_fields(self):
        self.store.upsert_npc(Npc(uid="u1"), 2000)
        self.assertEqual(self.store.npc("u1"), self.npc)

    def test_mood_is_per_player_and_clamped(self):
        self.assertEqual(self.store.mood("u1", "sp:0"), (0, 0))
        self.store.shift_mood("u1", "sp:0", 60, -5, 1)
        self.assertEqual(self.store.shift_mood("u1", "sp:0", 60, 0, 2), (100, -5))
        self.assertEqual(self.store.mood("u1", "other"), (0, 0))

    def test_drive_is_per_npc_clamped_and_settles_back(self):
        self.assertEqual(self.store.drive("u1", 0), 0)
        self.assertEqual(self.store.shift_drive("u1", 80, 0), 80)
        self.assertEqual(self.store.shift_drive("u1", 80, 0), 100, "clamped")
        self.assertEqual(self.store.drive("u1", GOAL_HALF_LIFE_MS), 50, "halves every half-life")
        self.assertEqual(self.store.shift_drive("u1", -60, GOAL_HALF_LIFE_MS), -10, "shifts from the settled value")
        self.assertEqual(self.store.drive("u2", 0), 0)

    def test_moods_lists_only_npcs_with_something_stored(self):
        self.store.shift_mood("u1", "sp:0", 20, 5, 0)
        self.store.shift_drive("u2", -40, 0)
        self.store.shift_mood("u3", "other", 50, 0, 0)
        self.assertEqual(self.store.moods(["u1", "u2", "u3", "u4"], "sp:0", GOAL_HALF_LIFE_MS), [
            {"uid": "u1", "trust": 20, "fear": 5, "goal": 0},
            {"uid": "u2", "trust": 0, "fear": 0, "goal": -20},
        ])

    def test_old_memories_become_one_summary(self):
        for index in range(16):
            self.store.add_memory("personal", "u1", ts=1000 + index, kind="dialogue", text=f"Note {index}.", importance=4)
        self.assertIsNone(self.store.summary_candidate(after=16, keep_recent=6), "not past the threshold yet")
        candidate = self.store.summary_candidate(after=14, keep_recent=6)
        self.assertEqual((candidate.scope, candidate.key, len(candidate.ids)), ("personal", "u1", 10))
        self.assertEqual((candidate.texts[0], candidate.texts[-1], candidate.last_ts), ("Note 0.", "Note 9.", 1009))
        self.assertIsNone(candidate.previous_text)
        self.store.apply_summary(candidate, "I talked a lot with the stranger.")
        recalled = [m.text for m in self.store.recall(self.npc, now=2000, limit=20)]
        self.assertEqual(recalled, [f"Note {index}." for index in range(10, 16)], "the summarized ones are out")
        self.assertEqual([(m.scope, m.text) for m in self.store.summaries(self.npc)],
                         [("personal", "I talked a lot with the stranger.")])
        self.assertIsNone(self.store.summary_candidate(after=14, keep_recent=6))
        for index in range(16, 26):
            self.store.add_memory("personal", "u1", ts=1000 + index, kind="dialogue", text=f"Note {index}.", importance=4)
        again = self.store.summary_candidate(after=14, keep_recent=6)
        self.assertEqual(again.previous_text, "I talked a lot with the stranger.", "the old summary is folded in")
        self.store.apply_summary(again, "Newer summary.")
        self.assertEqual([m.text for m in self.store.summaries(self.npc)], ["Newer summary."])
        self.assertIsNone(self.store.summary_candidate(after=14, keep_recent=6, skip=set()))

    def test_a_skipped_layer_is_left_alone(self):
        for index in range(15):
            self.store.add_memory("squad", "g1", ts=index, kind="died", text=f"We lost {index}.", importance=6)
        self.assertIsNone(self.store.summary_candidate(after=14, keep_recent=6, skip={("squad", "g1")}))
        self.assertEqual(self.store.summary_candidate(after=14, keep_recent=6).key, "g1")

    def test_layer_names_for_the_prompt(self):
        self.store.upsert_npc(Npc(uid="u2", name="Gus", faction_id="police", faction_name="County Police", group_id="g2"), 1)
        self.assertEqual(self.store.layer_name("personal", "u2"), "Gus")
        self.assertEqual(self.store.layer_name("squad", "g2"), "a group of County Police")
        self.assertEqual(self.store.layer_name("faction", "Apocalypse/save|police"), "County Police")
        self.assertEqual(self.store.layer_name("squad", "unknown"), "a group of survivors")

    def test_recall_spans_layers_and_ranks_by_importance_recency_and_relevance(self):
        now = 10 * DAY_MS
        self.store.add_memory("personal", "u1", ts=now - DAY_MS, kind="x", text="The stranger shared water with me.", importance=3)
        self.store.add_memory("squad", "g1", ts=now, kind="x", text="The stranger attacked Hobbs Scout.", importance=5)
        self.store.add_memory("faction", "hobbs", ts=now - 9 * DAY_MS, kind="x", text="Raiders burned the farm.", importance=2)
        self.store.add_memory("squad", "other-group", ts=now, kind="x", text="Not ours.", importance=10)
        recalled = [m.text for m in self.store.recall(self.npc, query="any water left?", now=now, limit=2)]
        self.assertEqual(recalled, ["The stranger shared water with me.", "The stranger attacked Hobbs Scout."])
        everything = self.store.recall(self.npc, now=now, limit=10)
        self.assertNotIn("Not ours.", [m.text for m in everything])
        self.assertEqual([m.ts for m in everything], sorted(m.ts for m in everything), "oldest first")

    def test_add_memory_ignores_empty_text_or_scope(self):
        self.assertFalse(self.store.add_memory("squad", None, ts=1, kind="x", text="t", importance=1))
        self.assertFalse(self.store.add_memory("personal", "u1", ts=1, kind="x", text="  ", importance=1))
        with self.assertRaises(ValueError):
            self.store.add_memory("galaxy", "u1", ts=1, kind="x", text="t", importance=1)

    def test_recent_turns_are_ordered_and_limited(self):
        for index in range(5):
            self.store.add_turn("u1", "sp:0", ts=index, speaker="player" if index % 2 == 0 else "npc", text=str(index))
        self.assertEqual(self.store.recent_turns("u1", "sp:0", 3), [("player", "2"), ("npc", "3"), ("player", "4")])


class ExperienceTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore(":memory:")

    def tearDown(self):
        self.store.close()

    def hit(self, ts, weapon="Base.Hammer", by=None):
        return apply_event(self.store, {
            "kind": "npc_hit", "weapon": weapon, "by": by or {"kind": "player", "key": "sp:0"},
            "npc": {"uid": "u1", "name": "Hobbs Rifleman", "factionId": "hobbs", "groupId": "g1"},
        }, ts)

    def test_weapon_names(self):
        self.assertEqual(weapon_name("Base.HuntingKnife"), "hunting knife")
        self.assertIsNone(weapon_name("Base.BareHands"))
        self.assertIsNone(weapon_name(None))

    def test_player_hit_writes_personal_and_squad_memories_and_shifts_mood(self):
        self.assertEqual(self.hit(1000), 2)
        self.assertEqual(self.store.mood("u1", "sp:0"), (-10, 8))
        texts = [m.text for m in self.store.recall(self.store.npc("u1"), now=1000)]
        self.assertIn("The stranger hit me with a hammer.", texts)
        self.assertIn("The stranger attacked Hobbs Rifleman.", texts)

    def test_repeated_hits_shift_mood_but_do_not_spam_memories(self):
        self.hit(1000)
        self.assertEqual(self.hit(20_000), 0)
        self.assertEqual(self.store.mood("u1", "sp:0"), (-20, 16))
        self.assertEqual(self.hit(200_000), 2, "a new memory after the repeat window")

    def test_kill_by_player_is_remembered_by_squad_and_faction(self):
        written = apply_event(self.store, {"kind": "npc_died", "by": {"kind": "player", "key": "sp:0"},
                                           "npc": {"uid": "u2", "name": "Hobbs Scout", "factionId": "hobbs",
                                                   "groupId": "g1"}}, 5000)
        self.assertEqual(written, 2)
        squad_mate = Npc(uid="u3", faction_id="hobbs", group_id="g1")
        self.assertEqual([m.text for m in self.store.recall(squad_mate, now=5000)], ["The stranger killed Hobbs Scout."],
                         "its own squad hears it once, not again as news from another group")
        other_group = Npc(uid="u4", faction_id="hobbs", group_id="g2")
        self.assertEqual([m.text for m in self.store.recall(other_group, now=5000)],
                         ["The stranger killed Hobbs Scout, one of our people in another group."])

    def test_a_loss_names_who_did_it(self):
        # Play test (2026-10-11): "We lost Deputy Rowe." alone let the LLM blame the player.
        self.store.upsert_npc(Npc(uid="k1", name="Gus - Rifleman"), 1)
        def died(uid, by):
            apply_event(self.store, {"kind": "npc_died", "by": by,
                                     "npc": {"uid": uid, "name": f"Deputy {uid}", "factionId": "alife_police",
                                             "groupId": "g1"}}, 100 + len(uid))
        died("A", {"kind": "npc", "uid": "k2", "name": "Travis - Squad Leader"})
        died("BB", {"kind": "npc", "uid": "k1"})
        died("CCC", {"kind": "npc", "uid": "k9"})
        died("DDDD", {"kind": "other"})
        texts = [m.text for m in self.store.recall(Npc(uid="u5", group_id="g1"), now=200, limit=10)]
        self.assertEqual(texts, ["Travis - Squad Leader killed Deputy A, not the stranger.",
                                 "Gus - Rifleman killed Deputy BB, not the stranger.",
                                 "Another survivor killed Deputy CCC, not the stranger.",
                                 "We lost Deputy DDDD; nobody saw who did it."])

    def test_faction_memories_stay_in_their_save(self):
        # Play test (2026-10-11): deputies blamed the player for "Deputy Rowe" killed in an older test save.
        died = {"kind": "npc_died", "by": {"kind": "player", "key": "sp:0"},
                "npc": {"uid": "u2", "name": "Deputy Rowe", "factionId": "alife_police", "groupId": "g1"}}
        apply_event(self.store, died, 1000)  # before saves were told apart: no world
        apply_event(self.store, died, 2000, world="Apocalypse/old test")
        colleague = Npc(uid="u9", faction_id="alife_police", group_id="g7")
        def faction_texts(world):
            return [m.text for m in self.store.recall(colleague, now=3000, world=world) if m.scope == "faction"]
        self.assertEqual(faction_texts("Apocalypse/new game"), [])
        self.assertEqual(faction_texts("Apocalypse/old test"),
                         ["The stranger killed Deputy Rowe, one of our people in another group."])
        self.assertEqual(len(faction_texts(None)), 1, "a sidecar talking to an older mod still finds the old ones")

    def test_action_outcomes_become_memories_and_system_turns(self):
        base = {"kind": "npc_action", "by": {"kind": "player", "key": "sp:0"},
                "npc": {"uid": "u1", "name": "Henry"}}
        self.assertEqual(apply_event(self.store, dict(base, action="give", ok=True, item="water",
                                                      label="Water Bottle"), 10), 1)
        self.assertEqual(apply_event(self.store, dict(base, action="give", ok=False, item="food",
                                                      reason="no_item"), 20), 1)
        self.assertEqual(apply_event(self.store, dict(base, action="follow", ok=True), 30), 1)
        self.assertEqual(apply_event(self.store, dict(base, action="dance", ok=True), 40), 0)
        self.assertEqual([text for _, text in self.store.recent_turns("u1", "sp:0", 10)], [
            "Henry handed over Water Bottle.",
            "Henry did not hand over any food: had none to spare.",
            "Henry started following the stranger.",
        ])
        texts = [m.text for m in self.store.recall(self.store.npc("u1"), now=40, limit=10)]
        self.assertIn("I gave the stranger Water Bottle.", texts)
        self.assertIn("I meant to give the stranger food but had none to spare.", texts)

    def test_trade_outcomes(self):
        base = {"kind": "npc_action", "action": "trade", "by": {"kind": "player", "key": "sp:0"},
                "npc": {"uid": "u1", "name": "Henry"}}
        apply_event(self.store, dict(base, ok=True, given=["Konserve Fasulye"], received=["Bandaj", "Bandaj"]), 10)
        apply_event(self.store, dict(base, ok=True, given=[], received=["Bandaj"]), 20)
        apply_event(self.store, dict(base, ok=False, reason="rejected"), 30)
        apply_event(self.store, dict(base, ok=False, reason="changed"), 40)
        self.assertEqual([text for _, text in self.store.recent_turns("u1", "sp:0", 10)], [
            "Trade done: Henry gave Konserve Fasulye and got Bandaj, Bandaj.",
            "Trade done: Henry gave nothing and got Bandaj.",
            "Henry turned the trade down.",
            "The trade did not happen: the items were no longer there.",
        ])
        texts = [m.text for m in self.store.recall(self.store.npc("u1"), now=40, limit=10)]
        self.assertIn("I traded my Konserve Fasulye for the stranger's Bandaj, Bandaj.", texts)
        self.assertIn("The stranger gave me Bandaj.", texts)
        self.assertEqual(self.store.mood("u1", "sp:0"), (2 + 6, 0), "a fair swap +2, a gift +6, failures nothing")

    def test_a_trade_in_a_fight_says_so(self):
        apply_event(self.store, {"kind": "npc_action", "action": "trade", "ok": False, "reason": "combat",
                                 "by": {"kind": "player", "key": "sp:0"}, "npc": {"uid": "u1", "name": "Carla"}}, 10)
        self.assertEqual(self.store.recent_turns("u1", "sp:0", 1),
                         [("system", "The trade did not happen: was in the middle of a fight.")])

    def test_a_hit_among_the_dead_is_an_accident(self):
        apply_event(self.store, {"kind": "npc_hit", "weapon": "MarzGuns.MOSSBERG_590", "zombiesNear": 3,
                                 "by": {"kind": "player", "key": "sp:0"},
                                 "npc": {"uid": "u1", "name": "Guard Sergeant", "groupId": "g1"}}, 1000)
        self.assertEqual(self.store.mood("u1", "sp:0"), (-3, 2))
        texts = [m.text for m in self.store.recall(self.store.npc("u1"), now=1000)]
        self.assertEqual(texts, ["The stranger hit me by accident while we were fighting the dead."],
                         "no squad memory of an attack")
        self.hit(200_000)  # nothing around: an attack
        self.assertEqual(self.store.mood("u1", "sp:0"), (-13, 10))

    def test_fighting_the_dead_beside_an_npc_builds_trust(self):
        helped = {"kind": "player_helped", "by": {"kind": "player", "key": "sp:0"},
                  "npc": {"uid": "u1", "name": "Vernon - Engineer", "groupId": "g1"}}
        self.assertEqual(apply_event(self.store, dict(helped, kills=1), 1000), 2)
        self.assertEqual(self.store.mood("u1", "sp:0"), (3, -1))
        self.assertEqual(apply_event(self.store, dict(helped, kills=4), 61_000), 0, "remembered once in a while")
        self.assertEqual(self.store.mood("u1", "sp:0"), (7, -2), "more kills, a little more trust")
        texts = [m.text for m in self.store.recall(Npc(uid="u1", group_id="g1"), now=61_000)]
        self.assertIn("The stranger killed one of the dead right next to me.", texts)
        self.assertIn("The stranger fought the dead beside Vernon - Engineer.", texts)
        self.assertEqual(apply_event(self.store, {"kind": "player_helped", "by": {"kind": "npc", "uid": "x"},
                                                  "npc": helped["npc"]}, 70_000), 0, "only the player's help")

    def test_a_crew_remembers_robbing_the_stranger(self):
        crew = [{"uid": "r1", "name": "Andre - Crew Boss", "factionId": "pickers", "groupId": "g9"},
                {"uid": "r2", "name": "Lyle - Picker", "factionId": "pickers", "groupId": "g9"}]
        robbed = {"kind": "robbed_player", "npc": crew[0], "crew": crew, "by": {"kind": "player", "key": "sp:0"}}
        apply_event(self.store, dict(robbed, outcome="released", taken=["Hammer", "Water Bottle"]), 1000)
        for uid in ("r1", "r2"):
            self.assertEqual([m.text for m in self.store.recall(Npc(uid=uid), now=1000) if m.scope == "personal"],
                             ["We robbed the stranger and took their Hammer, Water Bottle."])
            self.assertEqual(self.store.mood(uid, "sp:0"), (1, -2), "the stranger gave in")
        self.assertEqual(self.store.recent_turns("r1", "sp:0", 1),
                         [("system", "Andre - Crew Boss's crew robbed the stranger and took Hammer, Water Bottle.")])
        apply_event(self.store, dict(robbed, outcome="execute:drew_weapon", taken=[]), 2000)
        self.assertEqual(self.store.mood("r2", "sp:0"), (1 - 3, -2 + 3))
        texts = [m.text for m in self.store.recall(Npc(uid="r2", group_id="g9"), now=2000, limit=10)]
        self.assertIn("We tried to rob the stranger; they drew a weapon, so we opened fire.", texts)
        apply_event(self.store, dict(robbed, outcome="player_gone"), 3000)
        self.assertEqual(self.store.mood("r1", "sp:0"), (-2, 1), "nothing happened: no change")
        self.assertEqual(apply_event(self.store, dict(robbed, by={"kind": "npc", "uid": "x"}, outcome="released"), 4000),
                         0, "only robberies of a player")

    def test_ignores_events_without_an_npc(self):
        self.assertEqual(apply_event(self.store, {"kind": "npc_hit"}, 1), 0)
        self.assertEqual(apply_event(self.store, "junk", 1), 0)


if __name__ == "__main__":
    unittest.main()
