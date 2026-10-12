import sqlite3
import tempfile
import unittest
from pathlib import Path

from alifebrain_sidecar.memory import SUMMARY_LIMIT, MemoryStore, Npc, SummaryCandidate
from alifebrain_sidecar.summary import InvalidSummary, build_summary_messages, parse_summary


class SummaryPromptTests(unittest.TestCase):
    def test_prompt_names_the_layer_and_lists_the_memories(self):
        candidate = SummaryCandidate("squad", "g1", (1, 2), ("We lost Rowe.", "The stranger fought beside Gus."), 5,
                                     previous_id=9, previous_text="We met the stranger at the bridge.")
        system, user = build_summary_messages(candidate, "a group of County Police")
        self.assertIn("a group of County Police", system["content"])
        self.assertIn('("we")', system["content"])
        self.assertIn("Never add anything", system["content"])
        self.assertIn("Earlier summary: We met the stranger at the bridge.", user["content"])
        self.assertTrue(user["content"].endswith("- We lost Rowe.\n- The stranger fought beside Gus."))

    def test_parses_plain_quoted_fenced_and_json_replies(self):
        for text in ('I traded with the stranger twice.', '"I traded with the stranger twice."',
                     "```\nI traded with the stranger twice.\n```", '{"summary": "I traded with the stranger twice."}',
                     "Summary: I traded with the stranger twice."):
            with self.subTest(text=text):
                self.assertEqual(parse_summary(text), "I traded with the stranger twice.")

    def test_long_replies_are_cut_and_empty_ones_refused(self):
        self.assertLessEqual(len(parse_summary("I remember. " * 80)), SUMMARY_LIMIT + 3)
        for text in ("", "  ", "{}", '"ok"'):
            with self.subTest(text=text), self.assertRaises(InvalidSummary):
                parse_summary(text)


class MigrationTests(unittest.TestCase):
    def test_an_older_database_gets_the_summarized_column(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "memory.sqlite3"
            old = sqlite3.connect(path)
            old.execute("CREATE TABLE memories (id INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL, "
                        "scope_key TEXT NOT NULL, player_key TEXT, ts INTEGER NOT NULL, kind TEXT NOT NULL, "
                        "text TEXT NOT NULL, importance INTEGER NOT NULL)")
            old.execute("INSERT INTO memories (scope, scope_key, ts, kind, text, importance) "
                        "VALUES ('personal', 'u1', 1, 'dialogue', 'An old note.', 4)")
            old.commit()
            old.close()
            store = MemoryStore(path)
            try:
                columns = {row[1] for row in store.db.execute("PRAGMA table_info(memories)")}
                self.assertIn("summarized", columns)
                self.assertEqual([m.text for m in store.recall(Npc(uid="u1"), now=2)], ["An old note."])
            finally:
                store.close()


if __name__ == "__main__":
    unittest.main()
