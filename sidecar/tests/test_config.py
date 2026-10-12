import json
import tempfile
import unittest
from pathlib import Path

from alifebrain_sidecar.config import load_settings


class LoadSettingsTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "config.json"

    def tearDown(self):
        self.dir.cleanup()

    def write(self, values):
        self.path.write_text(json.dumps(values), encoding="utf-8")

    def test_writes_defaults_on_first_run(self):
        settings = load_settings(self.path, environ={})
        self.assertEqual(settings.dialogue.timeout_s, 60.0)
        self.assertEqual(json.loads(self.path.read_text(encoding="utf-8"))["dialogue"]["timeout_s"], 60.0)

    def test_an_old_default_left_in_the_file_is_upgraded(self):
        self.write({"dialogue": {"timeout_s": 30.0, "max_tokens": 200}})
        settings = load_settings(self.path, environ={})
        self.assertEqual(settings.dialogue.timeout_s, 60.0)
        self.assertEqual(settings.dialogue.max_tokens, 200)

    def test_a_chosen_value_stays(self):
        self.write({"dialogue": {"timeout_s": 40}})
        self.assertEqual(load_settings(self.path, environ={}).dialogue.timeout_s, 40)

    def test_environment_overrides(self):
        self.write({})
        settings = load_settings(self.path, environ={"ALIFEBRAIN_PROVIDER": "fake"})
        self.assertEqual(settings.provider, "fake")
        with self.assertRaises(ValueError):
            load_settings(self.path, environ={"ALIFEBRAIN_PROVIDER": "nope"})


if __name__ == "__main__":
    unittest.main()
