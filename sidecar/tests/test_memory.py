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
        survivor = Npc(uid="u3", faction_id="hobbs", group_id="g1")
        texts = [m.text for m in self.store.recall(survivor, now=5000)]
        self.assertIn("The stranger killed Hobbs Scout.", texts)
        self.assertIn("The stranger killed Hobbs Scout, one of our people.", texts)

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
        self.assertEqual(faction_texts("Apocalypse/old test"), ["The stranger killed Deputy Rowe, one of our people."])
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

    def test_ignores_events_without_an_npc(self):
        self.assertEqual(apply_event(self.store, {"kind": "npc_hit"}, 1), 0)
        self.assertEqual(apply_event(self.store, "junk", 1), 0)


if __name__ == "__main__":
    unittest.main()
