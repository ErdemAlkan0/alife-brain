import json
import tempfile
import unittest
from pathlib import Path

from alifebrain_sidecar.dataset import DatasetStore

NAMES = ["health", "threat", "night"]


def row(**overrides):
    data = {"d": "decision", "a": "regroup", "o": [1, 0, 0.5], "m": ["regroup", "orders"], "u": "palife:1:7",
            "f": "alife_church_volunteers", "p": "volunteer", "t": 1791496029466}
    data.update(overrides)
    return data


class DatasetStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name) / "dataset"
        self.store = DatasetStore(self.dir, day=lambda: "2026-10-09")

    def tearDown(self):
        self.temp.cleanup()

    def lines(self):
        path = self.dir / "decisions-2026-10-09.jsonl"
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def test_stores_valid_rows_and_the_schema(self):
        stored = self.store.add_batch({"kind": "decision_samples", "schema": 1, "names": NAMES,
                                       "rows": [row(), row(d="response", a="default", pa="flee")]},
                                      ts=5, session="s1")
        self.assertEqual(stored, 2)
        first, second = self.lines()
        self.assertEqual(first, {"schema": 1, "session": "s1", "ts": 1791496029466, "dispatch": "decision",
                                 "label": "regroup", "obs": [1.0, 0.0, 0.5], "allowed": ["regroup", "orders"],
                                 "uid": "palife:1:7", "faction": "alife_church_volunteers", "profile": "volunteer"})
        self.assertEqual((second["dispatch"], second["policy"]), ("response", "flee"))
        schema = json.loads((self.dir / "schema-1.json").read_text(encoding="utf-8"))
        self.assertEqual(schema, {"schema": 1, "names": NAMES})

    def test_marks_the_policys_picks_and_policy_control(self):
        self.store.add_batch({"kind": "decision_samples", "schema": 1, "names": NAMES,
                              "rows": [row(c=True, ctl=True, pa="regroup"), row(ctl=True), row(c="yes")]},
                             ts=5, session="s1")
        picked, alife, junk = self.lines()
        self.assertEqual((picked["chosen"], picked["control"], picked["policy"]), (True, True, "regroup"))
        self.assertEqual((alife.get("chosen"), alife["control"]), (None, True))
        self.assertNotIn("chosen", junk, "only a real true marks a row")

    def test_drops_rows_that_do_not_fit(self):
        self.store.add_batch({"schema": 1, "names": NAMES, "rows": [row()]}, ts=5, session="s1")
        bad = [row(o=[1, 0]), row(d="positioning"), row(a="bad label!"), row(o=[1, True, 0]),
               row(o=[1, float("nan"), 0]), "nope", row(m="regroup")]
        stored = self.store.add_batch({"schema": 1, "rows": bad}, ts=6, session="s1")
        self.assertEqual(stored, 1, "only the row whose allowed list was not a list survives (as empty)")
        self.assertEqual(self.lines()[-1]["allowed"], [])
        self.assertEqual(self.store.rejected, 6)
        self.assertEqual(self.store.add_batch({"schema": "1", "rows": [row()]}, ts=7, session="s1"), 0)

    def test_keeps_the_first_names_of_a_schema_across_restarts(self):
        self.store.add_batch({"schema": 1, "names": NAMES, "rows": []}, ts=5, session="s1")
        again = DatasetStore(self.dir, day=lambda: "2026-10-09")
        self.assertEqual(again.names[1], NAMES)
        with self.assertLogs("alifebrain_sidecar.dataset", "WARNING"):
            again.add_batch({"schema": 1, "names": ["other", "names", "here"], "rows": []}, ts=6, session="s2")
        self.assertEqual(again.names[1], NAMES)


if __name__ == "__main__":
    unittest.main()
