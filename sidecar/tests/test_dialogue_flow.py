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
from alifebrain_sidecar.memory import MemoryStore
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

    def test_history_needs_uid_and_player(self):
        history_id = self.send("history", {"uid": "u1"})
        self.sidecar.step()
        self.assertEqual(self.responses()[history_id]["error"], "uid_or_player_missing")


class ProviderFailureTests(FlowTestCase):
    def test_llm_errors_are_reported_with_their_code(self):
        self.sidecar.provider = ScriptedProvider(LLMError("rate_limited"))
        request_id = self.send("dialogue", self.talk())
        self.sidecar.step()
        reply = self.responses()[request_id]
        self.assertFalse(reply["ok"])
        self.assertEqual(reply["error"], "rate_limited")
        self.assertEqual(self.memory.recent_turns("u1", "sp:0"), [], "failed exchanges are not remembered")

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
