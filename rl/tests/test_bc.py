import json
import re
import tempfile
import unittest
from pathlib import Path

import numpy as np

from alifebrain_rl.bc import main, split, train_dispatch
from alifebrain_rl.data import DEFAULT, load
from alifebrain_rl.export import lua_value
from alifebrain_rl.mlp import MLP, loss_and_grad

NAMES = ["threat", "afraid", "order_follow", "noise_a", "noise_b", "noise_c"]


def synthetic_rows(count: int, seed: int = 3) -> list[dict]:
    """A known rule: threatened and afraid -> flee (only some NPCs may), following an
    order -> orders, otherwise patrolRest; nothing else matters."""
    rng = np.random.default_rng(seed)
    rows = []
    for index in range(count):
        threat, afraid, order = (rng.random(3) < 0.4).astype(int)
        may_flee = index % 3 != 0
        allowed = ["orders", "patrolRest"] + (["flee"] if may_flee else [])
        if threat and afraid:
            label = "flee" if may_flee else DEFAULT
        elif order:
            label = "orders"
        else:
            label = "patrolRest"
        obs = [float(threat), float(afraid), float(order), *rng.random(3).round(3).tolist()]
        rows.append({"schema": 1, "dispatch": "decision", "label": label, "obs": obs, "allowed": allowed,
                     "uid": f"palife:{index % 40}", "ts": 1_000 + index})
    return rows


def write_dataset(directory: Path, rows: list[dict]) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "schema-1.json").write_text(json.dumps({"schema": 1, "names": NAMES}), encoding="utf-8")
    with (directory / "decisions-2026-10-09.jsonl").open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")
        handle.write('{"schema": 1, "dispatch": "deci')  # a line cut short by a crash


class DataTests(unittest.TestCase):
    def test_loads_actions_masks_and_npcs(self):
        with tempfile.TemporaryDirectory() as temp:
            write_dataset(Path(temp), synthetic_rows(60) + [dict(synthetic_rows(1)[0], obs=[1, 2])])
            dataset = load(Path(temp), "decision")
            self.assertEqual(len(dataset), 60, "the short obs row and the broken line are skipped")
            self.assertEqual(dataset.actions, [DEFAULT, "flee", "orders", "patrolRest"])
            self.assertTrue(dataset.masks[:, 0].all(), "A-Life's fallback is always possible")
            self.assertTrue(dataset.masks[np.arange(60), dataset.labels].all(), "what A-Life did was allowed")
            self.assertFalse(dataset.masks[0, 1], "NPC 0 may not flee")
            self.assertEqual(len(np.unique(dataset.groups)), 40)
            self.assertIsNone(load(Path(temp), "response"))

    def test_leaves_out_excluded_labels(self):
        with tempfile.TemporaryDirectory() as temp:
            write_dataset(Path(temp), synthetic_rows(60))
            dataset = load(Path(temp), "decision", exclude=frozenset({"orders"}))
            self.assertNotIn(dataset.actions.index("orders"), set(dataset.labels.tolist()))
            self.assertIn("orders", dataset.actions, "still something the NPC may do")

    def test_validation_holds_out_whole_npcs(self):
        with tempfile.TemporaryDirectory() as temp:
            write_dataset(Path(temp), synthetic_rows(400))
            dataset = load(Path(temp), "decision")
            train_rows, val_rows = split(dataset, np.random.default_rng(0))
            self.assertFalse(set(dataset.groups[train_rows]) & set(dataset.groups[val_rows]))
            self.assertEqual(len(train_rows) + len(val_rows), 400)


class MlpTests(unittest.TestCase):
    def test_gradients_match_finite_differences(self):
        rng = np.random.default_rng(1)
        model = MLP([4, 5, 3], rng)
        model.weights[-1] *= 100  # away from the near-zero start, so the check means something
        x, labels = rng.normal(size=(6, 4)), np.array([0, 1, 2, 1, 0, 2])
        masks = np.ones((6, 3), dtype=bool)
        masks[0, 2] = False
        weights = np.linspace(0.5, 1.5, 6)
        logits, activations = model.forward(x)
        _, grad = loss_and_grad(logits, labels, masks, weights)
        analytic = model.backward(activations, grad)
        for param, expected in zip(model.params, analytic):
            index = tuple(rng.integers(0, size) for size in param.shape)
            saved = param[index]
            param[index] = saved + 1e-6
            up, _ = loss_and_grad(model.forward(x)[0], labels, masks, weights)
            param[index] = saved - 1e-6
            down, _ = loss_and_grad(model.forward(x)[0], labels, masks, weights)
            param[index] = saved
            self.assertAlmostEqual((up - down) / 2e-6, expected[index], places=5)


class TrainingTests(unittest.TestCase):
    def test_learns_a_known_rule_and_exports_it(self):
        with tempfile.TemporaryDirectory() as temp:
            data = Path(temp) / "dataset"
            write_dataset(data, synthetic_rows(1500))
            dataset = load(data, "decision")
            table, report = train_dispatch(dataset, hidden=[16, 16], epochs=150, seed=2, log=lambda _: None)
            self.assertGreater(report["accuracy"], 0.95, report)
            self.assertGreater(report["accuracy"], report["baseline"])
            self.assertEqual(table["actions"], dataset.actions)
            self.assertEqual([layer["act"] for layer in table["layers"]], ["tanh", "tanh", "linear"])
            self.assertEqual(np.asarray(table["layers"][0]["w"]).shape, (16, len(NAMES)), "one row per output")

            out = Path(temp) / "PolicyWeights.lua"
            self.assertEqual(main(["--data", str(data), "--out", str(out), "--hidden", "16,16", "--epochs", "40"]), 0)
            text = out.read_text(encoding="utf-8")
            self.assertIn("ALifeBrain.PolicyWeights = {", text)
            self.assertIn('actions = { "default", "flee", "orders", "patrolRest" }', text)
            self.assertIn("check = {", text)
            self.assertTrue(text.rstrip().endswith("return ALifeBrain.PolicyWeights"))

    def test_too_little_data_writes_nothing(self):
        with tempfile.TemporaryDirectory() as temp:
            data = Path(temp) / "dataset"
            write_dataset(data, synthetic_rows(50))
            out = Path(temp) / "PolicyWeights.lua"
            self.assertEqual(main(["--data", str(data), "--out", str(out)]), 1)
            self.assertFalse(out.exists())


def parse_lua(text: str):
    """Just enough Lua to read PolicyWeights.lua back: tables, numbers, strings, booleans."""
    position = 0

    def skip():
        nonlocal position
        while position < len(text) and text[position] in " \t\r\n,":
            position += 1

    def value():
        nonlocal position
        skip()
        char = text[position]
        if char == "{":
            position += 1
            items, fields = [], {}
            while True:
                skip()
                if text[position] == "}":
                    position += 1
                    return fields if fields else items
                match = re.match(r'\[("(?:[^"\\]|\\.)*")\]\s*=|([A-Za-z_]\w*)\s*=', text[position:])
                if match:
                    position += match.end()
                    key = json.loads(match.group(1)) if match.group(1) else match.group(2)
                    fields[key] = value()
                else:
                    items.append(value())
        if char == '"':
            match = re.match(r'"(?:[^"\\]|\\.)*"', text[position:])
            position += match.end()
            return json.loads(match.group(0))
        match = re.match(r"true|false|nil|-?[0-9.]+(?:e[-+]?\d+)?", text[position:])
        position += match.end()
        word = match.group(0)
        if word in ("true", "false", "nil"):
            return {"true": True, "false": False, "nil": None}[word]
        return float(word)

    return value()


def lua_logits(net: dict, vector: list[float]) -> list[float]:
    """Policy.logits from Policy.lua, line for line."""
    x = [((vector[i] if i < len(vector) else 0) - net["mean"][i]) / (net["std"][i] or 1) for i in range(len(net["mean"]))]
    for layer in net["layers"]:
        y = []
        for j, bias in enumerate(layer["b"]):
            total = bias + sum(weight * x[i] for i, weight in enumerate(layer["w"][j]))
            y.append(np.tanh(total) if layer["act"] == "tanh" else total)
        x = y
    return x


class ExportTests(unittest.TestCase):
    def test_the_game_reads_back_what_was_trained(self):
        with tempfile.TemporaryDirectory() as temp:
            data = Path(temp) / "dataset"
            write_dataset(data, synthetic_rows(900))
            out = Path(temp) / "PolicyWeights.lua"
            main(["--data", str(data), "--out", str(out), "--hidden", "12,8", "--epochs", "60"])
            text = out.read_text(encoding="utf-8")
            body = text.split("ALifeBrain.PolicyWeights = ", 1)[1].rsplit("return ALifeBrain.PolicyWeights", 1)[0]
            weights = parse_lua(body)
            net = weights["nets"]["decision"]
            self.assertEqual(weights["schema"], 1)
            self.assertEqual(weights["features"], NAMES)
            got = lua_logits(net, net["check"]["input"])
            for mine, stored in zip(got, net["check"]["logits"]):
                self.assertAlmostEqual(mine, stored, places=4)
            self.assertGreater(max(got) - min(got), 1.0, "the check input is one with clearly different scores")

    def test_lua_values(self):
        self.assertEqual(lua_value([1, 0.5, -2.25e-07, True, None]), "{ 1, 0.5, -2.25e-07, true, nil }")
        self.assertEqual(lua_value({"a": "x\"y", "end": 1, "two words": []}),
                         '{\n  a = "x\\"y",\n  ["end"] = 1,\n  ["two words"] = {},\n}')
        self.assertEqual(lua_value(np.array([[1.0, 2.0], [3.0, 4.0]])), "{\n  { 1, 2 },\n  { 3, 4 },\n}")
        with self.assertRaises(ValueError):
            lua_value(float("nan"))


if __name__ == "__main__":
    unittest.main()
