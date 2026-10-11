import json
import tempfile
import unittest
from pathlib import Path

from alifebrain_sidecar.app import Sidecar
from alifebrain_sidecar.dataset import DatasetStore
from alifebrain_sidecar.events import EventStore
from alifebrain_sidecar.files import FileBridge
from alifebrain_sidecar.memory import MemoryStore
from alifebrain_sidecar.protocol import CLAIMED_FILE, REQ_FILE, RES_FILE


class FakeClock:
    def __init__(self, now=1_000_000):
        self.now = now

    def __call__(self):
        return self.now


class SidecarTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.lua_dir = root / "Lua"
        self.lua_dir.mkdir()
        self.events_path = root / "data" / "events.jsonl"
        self.clock = FakeClock()
        self.sidecar = Sidecar(FileBridge(self.lua_dir), EventStore(self.events_path), clock=self.clock, sid="sidA")
        self.seq = 0

    def tearDown(self):
        self._tmp.cleanup()

    # Mimics Bridge.lua: append request lines to the request file.
    def send(self, kind, data=None, *, session="s1", ts=None, ack=None):
        self.seq += 1
        message = {"v": 1, "id": f"{session}:{self.seq}", "sess": session, "type": kind,
                   "ts": self.clock.now if ts is None else ts, "data": data}
        if ack is not None:
            message["ack"] = ack
        with (self.lua_dir / REQ_FILE).open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(message) + "\n")
        return message["id"]

    def read_res(self):
        lines = (self.lua_dir / RES_FILE).read_text(encoding="utf-8").splitlines()
        return json.loads(lines[0]), [json.loads(text) for text in lines[1:]]


class RoundTripTests(SidecarTestCase):
    def test_publishes_status_without_any_request(self):
        self.sidecar.step()
        status, responses = self.read_res()
        self.assertEqual(status["type"], "status")
        self.assertEqual(status["v"], 1)
        self.assertEqual(status["sid"], "sidA")
        self.assertEqual(status["ts"], self.clock.now)
        self.assertEqual(responses, [])

    def test_hello_and_ping_get_responses_in_order(self):
        hello = self.send("hello", {"mod": "ALifeBrain"})
        ping = self.send("ping", {"sentAt": 5})
        self.sidecar.step()
        _, responses = self.read_res()
        self.assertEqual([r["re"] for r in responses], [hello, ping])
        self.assertEqual([r["rseq"] for r in responses], [1, 2])
        self.assertTrue(all(r["ok"] for r in responses))
        self.assertEqual(responses[0]["data"]["sid"], "sidA")
        self.assertEqual(responses[1]["data"]["echo"], {"sentAt": 5})
        self.assertFalse((self.lua_dir / REQ_FILE).exists(), "request file was claimed")
        self.assertFalse((self.lua_dir / CLAIMED_FILE).exists(), "claimed file was deleted")

    def test_unknown_type_gets_an_error(self):
        request_id = self.send("teleport")
        self.sidecar.step()
        _, responses = self.read_res()
        self.assertEqual(responses[0]["re"], request_id)
        self.assertFalse(responses[0]["ok"])
        self.assertEqual(responses[0]["error"], "unknown_type")

    def test_ack_removes_delivered_responses(self):
        self.send("ping")
        self.send("ping")
        self.sidecar.step()
        self.send("ack", ack={"sid": "sidA", "rseq": 1})
        self.sidecar.step()
        _, responses = self.read_res()
        self.assertEqual([r["rseq"] for r in responses], [2])

    def test_ack_for_another_sidecar_is_ignored(self):
        self.send("ping")
        self.sidecar.step()
        self.send("ack", ack={"sid": "old", "rseq": 99})
        self.sidecar.step()
        _, responses = self.read_res()
        self.assertEqual(len(responses), 1)

    def test_new_game_session_drops_old_responses(self):
        self.send("ping", session="s1")
        self.sidecar.step()
        self.send("ping", session="s2")
        self.sidecar.step()
        status, responses = self.read_res()
        self.assertEqual(status["sess"], "s2")
        self.assertEqual([r["re"] for r in responses], ["s2:2"])

    def test_responses_expire(self):
        self.send("ping")
        self.sidecar.step()
        self.clock.now += self.sidecar.keep_ms + 1
        self.sidecar.step()
        _, responses = self.read_res()
        self.assertEqual(responses, [])


class RequestHandlingTests(SidecarTestCase):
    def test_events_are_stored_without_a_response(self):
        self.send("event", {"kind": "npc_hit", "npc": {"uid": "palife:1"}}, ts=self.clock.now - 60_000)
        self.sidecar.step()
        _, responses = self.read_res()
        self.assertEqual(responses, [])
        records = [json.loads(text) for text in self.events_path.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["event"]["kind"], "npc_hit")
        self.assertEqual(records[0]["ts"], self.clock.now - 60_000, "old backlog events are kept")
        self.assertEqual(records[0]["receivedTs"], self.clock.now)

    def test_decision_samples_go_to_the_dataset_not_the_event_log(self):
        self.send("event", {"kind": "decision_samples", "schema": 1, "rows": []})
        self.sidecar.step()
        _, responses = self.read_res()
        self.assertEqual(responses[0]["error"], "dataset_unavailable", "this sidecar has no dataset store")

        self.sidecar.dataset = DatasetStore(Path(self._tmp.name) / "data" / "dataset", day=lambda: "d")
        hello = self.send("hello", {})
        self.send("event", {"kind": "decision_samples", "schema": 1, "names": ["a", "b"],
                            "rows": [{"d": "decision", "a": "regroup", "o": [1, 0], "m": ["regroup"]}]})
        self.sidecar.step()
        _, responses = self.read_res()
        features = next(r for r in responses if r["re"] == hello)["data"]["features"]
        self.assertIn("dataset", features)
        self.assertEqual(self.sidecar.stats["samples"], 1)
        self.assertFalse(self.events_path.exists(), "samples are training data, not memories")
        self.assertTrue((Path(self._tmp.name) / "data" / "dataset" / "decisions-d.jsonl").exists())

    def test_policy_stats_are_logged_and_kept_but_are_no_memory(self):
        self.sidecar.memory = MemoryStore(":memory:")
        data = {"kind": "policy_stats", "decision": {"asked": 40, "ran": 12, "declined": 20, "near": 3, "left": 9},
                "response": {"asked": 5, "ran": 1}, "modules": {"decision:investigate": 9, "decision:fortify": 3},
                "reasons": []}
        self.send("event", data)
        with self.assertLogs("alifebrain_sidecar.app", level="INFO") as logs:
            self.sidecar.step()
        line = next(message for message in logs.output if "policy control" in message)
        self.assertIn("decision: asked 40, ran 12, nothing to do 20", line)
        self.assertIn("ran: decision:investigate x9, decision:fortify x3", line)
        records = [json.loads(text) for text in self.events_path.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(records[0]["event"]["kind"], "policy_stats")
        self.sidecar.memory.close()

    def test_event_without_kind_is_rejected(self):
        self.send("event", {"npc": {}})
        self.sidecar.step()
        _, responses = self.read_res()
        self.assertEqual(responses[0]["error"], "bad_event")
        self.assertFalse(self.events_path.exists())

    def test_stale_requests_are_dropped(self):
        self.send("ping", ts=self.clock.now - 31_000)
        self.sidecar.step()
        _, responses = self.read_res()
        self.assertEqual(responses, [])
        self.assertEqual(self.sidecar.stats.get("stale"), 1)

    def test_bad_lines_do_not_stop_the_batch(self):
        with (self.lua_dir / REQ_FILE).open("w", encoding="utf-8") as handle:
            handle.write("garbage\n\n")
        ping = self.send("ping")
        self.sidecar.step()
        _, responses = self.read_res()
        self.assertEqual([r["re"] for r in responses], [ping])
        self.assertEqual(self.sidecar.stats.get("bad_line"), 1)

    def test_duplicate_ids_are_handled_once(self):
        ping = self.send("ping")
        text = (self.lua_dir / REQ_FILE).read_text(encoding="utf-8")
        (self.lua_dir / REQ_FILE).write_text(text + text, encoding="utf-8")
        self.sidecar.step()
        _, responses = self.read_res()
        self.assertEqual([r["re"] for r in responses], [ping])

    def test_leftover_claimed_file_is_processed_first(self):
        leftover = {"v": 1, "id": "s1:old", "sess": "s1", "type": "ping", "ts": self.clock.now}
        (self.lua_dir / CLAIMED_FILE).write_text(json.dumps(leftover) + "\n", encoding="utf-8")
        new = self.send("ping")
        self.sidecar.step()
        self.sidecar.step()
        _, responses = self.read_res()
        self.assertEqual([r["re"] for r in responses], ["s1:old", new])


class HeartbeatTests(SidecarTestCase):
    def test_beat_advances_once_per_interval_when_idle(self):
        self.sidecar.step()
        first, _ = self.read_res()
        self.clock.now += 100
        self.sidecar.step()
        second, _ = self.read_res()
        self.assertEqual(second["beat"], first["beat"], "no rewrite inside the interval")
        self.clock.now += self.sidecar.heartbeat_ms
        self.sidecar.step()
        third, _ = self.read_res()
        self.assertEqual(third["beat"], first["beat"] + 1)

    def test_new_responses_publish_immediately(self):
        self.sidecar.step()
        self.clock.now += 10
        ping = self.send("ping")
        self.sidecar.step()
        _, responses = self.read_res()
        self.assertEqual([r["re"] for r in responses], [ping])


if __name__ == "__main__":
    unittest.main()
