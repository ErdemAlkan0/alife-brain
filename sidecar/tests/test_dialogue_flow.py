import json
import tempfile
import threading
import unittest
from concurrent.futures import Future, ThreadPoolExecutor
from pathlib import Path

from alifebrain_sidecar.app import Sidecar
from alifebrain_sidecar.events import EventStore
from alifebrain_sidecar.files import FileBridge
from alifebrain_sidecar.llm import FakeProvider, LLMError
from alifebrain_sidecar.memory import MemoryStore, Npc
from alifebrain_sidecar.protocol import REQ_FILE, RES_FILE


class ImmediateExecutor:
    """Runs submitted work synchronously so tests are deterministic."""

    def submit(self, fn, *args, **kwargs):
        future = Future()
        try:
            future.set_result(fn(*args, **kwargs))
        except Exception as error:
            future.set_exception(error)
        return future

    def shutdown(self, **kwargs):
        pass


class ScriptedProvider:
    name = "scripted"

    def __init__(self, *outputs):
        self.outputs = list(outputs)
        self.calls = []

    def chat(self, messages, **kwargs):
        self.calls.append(messages)
        output = self.outputs.pop(0)
        if isinstance(output, Exception):
            raise output
        return output


class FlowTestCase(unittest.TestCase):
    provider = None

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.lua_dir = root / "Lua"
        self.lua_dir.mkdir()
        self.now = 1_000_000
        self.memory = MemoryStore(":memory:")
        self.sidecar = Sidecar(FileBridge(self.lua_dir), EventStore(root / "events.jsonl"), memory=self.memory,
                               provider=self.provider, executor=ImmediateExecutor(), clock=lambda: self.now,
                               sid="sidA")
        self.seq = 0

    def tearDown(self):
        self.memory.close()
        self._tmp.cleanup()

    def send(self, kind, data):
        self.seq += 1
        message = {"v": 1, "id": f"s1:{self.seq}", "sess": "s1", "type": kind, "ts": self.now, "data": data}
        with (self.lua_dir / REQ_FILE).open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(message) + "\n")
        return message["id"]

    def responses(self):
        lines = (self.lua_dir / RES_FILE).read_text(encoding="utf-8").splitlines()
        return {r["re"]: r for r in map(json.loads, lines[1:])}

    @staticmethod
    def talk(text="Got any water?", uid="u1"):
        return {"text": text, "player": {"key": "sp:0"},
                "npc": {"uid": uid, "name": "Hobbs Rifleman", "factionId": "hobbs", "groupId": "g1"},
                "stance": "neutral"}


class FakeProviderFlowTests(FlowTestCase):
    provider = FakeProvider()

    def test_hello_advertises_dialogue(self):
        hello = self.send("hello", {})
        self.sidecar.step()
        self.assertIn("dialogue", self.responses()[hello]["data"]["features"])

    def test_dialogue_round_trip_writes_turns_memory_and_mood(self):
        request_id = self.send("dialogue", self.talk("Merhaba, su var mı?"))
        self.sidecar.step()
        reply = self.responses()[request_id]
        self.assertTrue(reply["ok"])
        self.assertIn("Merhaba, su var mı?", reply["data"]["say"])
        self.assertEqual((reply["data"]["intent"], reply["data"]["item"]), ("give", "water"))
        self.assertEqual((reply["data"]["trust"], reply["data"]["fear"]), (1, 0))
        self.assertEqual(self.memory.recent_turns("u1", "sp:0"),
                         [("player", "Merhaba, su var mı?"), ("npc", reply["data"]["say"])])
        notes = [m.text for m in self.memory.recall(self.memory.npc("u1"), now=self.now)]
        self.assertTrue(any("su var" in text for text in notes))

    def test_bad_dialogue_request_is_refused(self):
        request_id = self.send("dialogue", {"text": "hi"})
        self.sidecar.step()
        self.assertEqual(self.responses()[request_id]["error"], "npc_or_player_missing")

    def test_events_become_memories_used_in_the_next_prompt(self):
        provider = ScriptedProvider('{"say": "You hit me!"}')
        self.sidecar.provider = provider
        self.send("event", {"kind": "npc_hit", "weapon": "Base.Hammer", "by": {"kind": "player", "key": "sp:0"},
                            "npc": {"uid": "u1", "name": "Hobbs Rifleman", "factionId": "hobbs", "groupId": "g1"}})
        self.sidecar.step()
        self.send("dialogue", self.talk("Sorry about that."))
        self.sidecar.step()
        system = provider.calls[0][0]["content"]
        self.assertIn("The stranger hit me with a hammer.", system)
        self.assertIn("Your trust in them is -10 and your fear of them is 8", system)


class HistoryAndActionTests(FlowTestCase):
    provider = FakeProvider()

    def test_history_returns_turns_outcomes_and_mood(self):
        self.send("dialogue", self.talk("Can you spare some water?"))
        self.sidecar.step()
        self.now += 1000
        self.send("event", {"kind": "npc_action", "action": "give", "ok": True, "item": "water",
                            "label": "Water Bottle", "by": {"kind": "player", "key": "sp:0"},
                            "npc": {"uid": "u1", "name": "Hobbs Rifleman"}})
        history_id = self.send("history", {"uid": "u1", "playerKey": "sp:0"})
        self.sidecar.step()
        history = self.responses()[history_id]["data"]
        self.assertEqual(history["name"], "Hobbs Rifleman")
        self.assertEqual([turn["speaker"] for turn in history["turns"]], ["player", "npc", "system"])
        self.assertEqual(history["turns"][2]["text"], "Hobbs Rifleman handed over Water Bottle.")
        self.assertEqual(history["trust"], 1)

    def test_outcomes_reach_the_next_prompt(self):
        provider = ScriptedProvider('{"say": "There you go."}')
        self.sidecar.provider = provider
        self.send("event", {"kind": "npc_action", "action": "give", "ok": False, "item": "water",
                            "reason": "no_item", "by": {"kind": "player", "key": "sp:0"},
                            "npc": {"uid": "u1", "name": "Hobbs Rifleman"}})
        self.sidecar.step()
        self.send("dialogue", dict(self.talk("Where is my water?"),
                                   npc={"uid": "u1", "name": "Hobbs Rifleman", "inventory": {"food": 2}}))
        self.sidecar.step()
        system, user = provider.calls[0]
        self.assertIn("I meant to give the stranger water but had none to spare.", system["content"])
        self.assertIn("You carry and could hand over: 2 food items. ", system["content"])
        self.assertIn("(What actually happened) Hobbs Rifleman did not hand over any water", user["content"])

    def test_trade_round_trip_with_the_fake_provider(self):
        request_id = self.send("dialogue", dict(self.talk("Takas?"),
                                                trade={"playerOffer": [{"name": "Bandaj"}], "npcSide": []}))
        self.sidecar.step()
        data = self.responses()[request_id]["data"]
        self.assertEqual((data["intent"], data["trade"]),
                         ("trade", {"decision": "accept", "npcOffer": [], "npcWants": []}))
        offer_id = self.send("dialogue", dict(self.talk("Bana ne teklif edersin?"),
                                              npc={"uid": "u1", "tradeable": [{"name": "Konserve Fasulye", "count": 2}]}))
        self.sidecar.step()
        self.assertEqual(self.responses()[offer_id]["data"]["trade"],
                         {"decision": "counter", "npcOffer": ["Konserve Fasulye"], "npcWants": []})
        talk = self.talk("Fasulyene karşılık bandaj vereyim.")
        deal_id = self.send("dialogue", dict(talk, player=dict(talk["player"], tradeable=[{"name": "Bandaj"}]),
                                             npc={"uid": "u1", "tradeable": [{"name": "Konserve Fasulye"}]}))
        self.sidecar.step()
        self.assertEqual(self.responses()[deal_id]["data"]["trade"],
                         {"decision": "counter", "npcOffer": ["Konserve Fasulye"], "npcWants": ["Bandaj"]})

    def test_a_standoff_opening_is_not_the_strangers_words(self):
        self.sidecar.provider = ScriptedProvider('{"say": "Dur orada! Ne taşıyorsun?", "intent": "warn"}')
        opening = self.send("dialogue", dict(self.talk("(The stranger has just walked into your sights.)"),
                                             standoff={"opening": True}, stance="hostile"))
        self.sidecar.step()
        self.assertEqual(self.responses()[opening]["data"]["say"], "Dur orada! Ne taşıyorsun?")
        history = self.send("history", {"uid": "u1", "playerKey": "sp:0"})
        self.sidecar.step()
        turns = self.responses()[history]["data"]["turns"]
        self.assertEqual([(turn["speaker"], turn["text"]) for turn in turns], [("npc", "Dur orada! Ne taşıyorsun?")])

    def test_talk_of_danger_lowers_the_drive_the_game_reads_back(self):
        self.send("dialogue", self.talk("Be careful, there is a horde to the east."))
        self.sidecar.step()
        self.now += 1000
        moods = self.send("moods", {"playerKey": "sp:0", "uids": ["u1", "u9", 7]})
        history = self.send("history", {"uid": "u1", "playerKey": "sp:0"})
        hello = self.send("hello", {})
        self.sidecar.step()
        responses = self.responses()
        reply = next(r for r in responses.values() if "say" in (r.get("data") or {}))["data"]
        self.assertEqual((reply["goalDelta"], reply["goal"]), (-25, -25))
        self.assertEqual(responses[moods]["data"]["moods"], [{"uid": "u1", "trust": 1, "fear": 0, "goal": -25}])
        self.assertGreater(responses[moods]["data"]["goalHalfLifeMs"], 0)
        self.assertEqual(responses[history]["data"]["goal"], -25)
        self.assertIn("moods", responses[hello]["data"]["features"])

    def test_moods_needs_uids_and_player(self):
        request_id = self.send("moods", {"uids": ["u1"]})
        self.sidecar.step()
        self.assertEqual(self.responses()[request_id]["error"], "uids_or_player_missing")

    def test_history_needs_uid_and_player(self):
        history_id = self.send("history", {"uid": "u1"})
        self.sidecar.step()
        self.assertEqual(self.responses()[history_id]["error"], "uid_or_player_missing")


class SummaryFlowTests(FlowTestCase):
    provider = FakeProvider()

    def remember(self, count, uid="u1"):
        for index in range(count):
            self.memory.add_memory("personal", uid, ts=self.now - 100_000 + index, kind="dialogue",
                                   text=f"The stranger asked about water {index}.", importance=4)

    def test_old_memories_are_summarized_while_idle_and_reach_the_prompt(self):
        self.memory.upsert_npc(Npc(uid="u1", name="Hobbs Rifleman"), self.now)
        self.remember(16)
        self.sidecar.step()  # sends the summary job (this executor finishes it at once)
        self.sidecar.step()  # stores it
        self.assertEqual(self.sidecar.stats.get("summaries"), 1)
        summaries = self.memory.summaries(self.memory.npc("u1"))
        self.assertEqual(len(summaries), 1)
        self.assertTrue(summaries[0].text.startswith("(test summary) The stranger asked about water 0."))
        provider = ScriptedProvider('{"say": "Hm."}')
        self.sidecar.provider = provider
        self.send("dialogue", self.talk("Remember me?"))
        self.sidecar.step()
        system = provider.calls[0][0]["content"]
        self.assertIn("From before:\n- Your past: (test summary)", system)
        self.assertNotIn("water 0.", system.split("What you remember:")[-1], "summarized notes are not listed again")

    def test_a_failed_summary_waits_and_nothing_runs_too_often(self):
        provider = ScriptedProvider(LLMError("timeout"), "I remember the stranger asking about water.")
        self.sidecar.provider = provider
        self.remember(16)
        self.sidecar.step()
        self.sidecar.step()
        self.assertEqual(self.sidecar.stats.get("summary_failed"), 1)
        self.now += self.sidecar.memory_settings.summary_every_s * 1000
        self.sidecar.step()
        self.assertEqual(len(provider.calls), 1, "the failed layer waits for its retry time")
        self.now += self.sidecar.memory_settings.summary_retry_s * 1000
        self.sidecar.step()
        self.sidecar.step()
        self.assertEqual(len(provider.calls), 2)
        self.assertEqual(self.sidecar.stats.get("summaries"), 1)

    def test_can_be_switched_off(self):
        self.sidecar.memory_settings.summarize = False
        self.remember(20)
        self.sidecar.step()
        self.assertIsNone(self.sidecar.summary_job)
        self.assertEqual(self.memory.summaries(Npc(uid="u1")), [])


class ProviderFailureTests(FlowTestCase):
    def test_llm_errors_are_reported_with_their_code(self):
        self.sidecar.provider = ScriptedProvider(LLMError("rate_limited"))
        request_id = self.send("dialogue", self.talk())
        self.sidecar.step()
        reply = self.responses()[request_id]
        self.assertFalse(reply["ok"])
        self.assertEqual(reply["error"], "rate_limited")
        self.assertEqual(self.memory.recent_turns("u1", "sp:0"), [], "failed exchanges are not remembered")
        self.assertEqual(len(self.sidecar.provider.calls), 1, "only a refusal is asked again")

    def test_a_refused_prompt_is_asked_again_short(self):
        # Play test (2026-10-11): Player2 refused the same prompt twice ("user input rejected", HTTP 400).
        refused = LLMError("http_400", '{"message":"user input rejected (HTTP 400): API returned unexpected status code"}')
        provider = ScriptedProvider(refused, '{"say": "Then build it. I will help."}')
        self.sidecar.provider = provider
        self.memory.add_memory("personal", "u1", ts=self.now - 10, kind="dialogue", text="The stranger burned the dead.",
                               importance=6)
        talk = self.talk("I plan to build a gate there.")
        talk["npc"]["tradeable"] = [{"name": "MSR788 Rifle", "count": 1}]
        request_id = self.send("dialogue", talk)
        self.sidecar.step()
        reply = self.responses()[request_id]
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["data"]["say"], "Then build it. I will help.")
        full, short = provider.calls[0][0]["content"], provider.calls[1][0]["content"]
        self.assertIn("The stranger burned the dead.", full)
        self.assertIn("MSR788 Rifle", full)
        self.assertTrue(short.startswith("(Role-play for the zombie survival video game Project Zomboid."))
        self.assertNotIn("The stranger burned the dead.", short)
        self.assertNotIn("MSR788 Rifle", short)
        self.assertTrue(provider.calls[1][1]["content"].endswith('"I plan to build a gate there."'))

    def test_invalid_llm_output_is_refused(self):
        self.sidecar.provider = ScriptedProvider("I am an AI language model and cannot")
        request_id = self.send("dialogue", self.talk())
        self.sidecar.step()
        self.assertEqual(self.responses()[request_id]["error"], "invalid_llm_reply")

    def test_dialogue_unavailable_without_a_provider(self):
        request_id = self.send("dialogue", self.talk())
        self.sidecar.step()
        self.assertEqual(self.responses()[request_id]["error"], "dialogue_unavailable")


class SlowProviderTests(FlowTestCase):
    def test_heartbeat_continues_while_the_llm_thinks(self):
        release = threading.Event()

        class SlowProvider:
            name = "slow"

            def chat(self, messages, **kwargs):
                release.wait(5)
                return '{"say": "Finally."}'

        executor = ThreadPoolExecutor(max_workers=1)
        self.sidecar.executor = executor
        self.sidecar.provider = SlowProvider()
        request_id = self.send("dialogue", self.talk())
        self.sidecar.step()
        beats = []
        for _ in range(3):
            self.now += self.sidecar.heartbeat_ms
            self.sidecar.step()
            status = json.loads((self.lua_dir / RES_FILE).read_text(encoding="utf-8").splitlines()[0])
            beats.append(status["beat"])
        self.assertEqual(beats, sorted(set(beats)), "beat keeps advancing")
        self.assertNotIn(request_id, self.responses())
        release.set()
        executor.shutdown(wait=True)
        self.sidecar.step()
        self.assertEqual(self.responses()[request_id]["data"]["say"], "Finally.")


if __name__ == "__main__":
    unittest.main()
