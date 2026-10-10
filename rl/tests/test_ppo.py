import math
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_bc import lua_logits, parse_lua  # noqa: E402

from alifebrain_rl.features import NAMES, vector  # noqa: E402
from alifebrain_rl.sim import ACTIONS, DECISION_ACTIONS, RESPONSE_ACTIONS, SquadEnv  # noqa: E402


def index_of(name):
    return NAMES.index(name)


class FeatureTests(unittest.TestCase):
    """Same cases as BehaviorTests.lua "Features": the Python copy must match the game's."""

    def test_matches_the_game(self):
        out = vector({"health": 0.5, "maxHealth": 1, "wounds": 9, "threat": True, "threatKind": "player",
                      "threatDistance": 15, "zombiesNear": 3, "stance": "careful", "hour": 23, "order": "follow",
                      "previous": "combat", "trust": 250, "fear": -40, "weaponClass": "rifle", "rounds": 15})
        self.assertEqual(len(out), len(NAMES))
        expected = {"health": 0.5, "wounds": 1, "threat_player": 1, "threat_zombie": 0, "threat_distance": 0.5,
                    "stance_careful": 1, "night": 1, "order_follow": 1, "was_combat": 1, "trust": 1, "fear": -0.4,
                    "firearm": 1, "rounds": 0.5}
        for name, value in expected.items():
            self.assertAlmostEqual(out[index_of(name)], value, msg=name)
        self.assertTrue(all(-1 <= value <= 1 for value in out))

    def test_defaults(self):
        out = vector(None)
        for name, value in {"health": 1, "endurance": 1, "threat_distance": 1, "player_distance": 1,
                            "stance_neutral": 0}.items():
            self.assertEqual(out[index_of(name)], value, name)


def first_step(fixed, action_name, chain, seeds=300):
    """Mean reward and health after one action from many starts with fixed pinned."""
    index = ACTIONS.index((chain, action_name))
    rewards, health = [], []
    env = SquadEnv(fixed=fixed)
    for seed in range(seeds):
        env.reset(seed=seed)
        _, reward, *_ = env.step(index)
        rewards.append(reward)
        health.append(env.health)
    return float(np.mean(rewards)), float(np.mean(health))


class SimTests(unittest.TestCase):
    def test_gymnasium_api(self):
        from gymnasium.utils.env_checker import check_env
        check_env(SquadEnv(), skip_render_check=True)

    def test_observations_stay_in_range_and_valid_actions_fit_the_chain(self):
        env = SquadEnv()
        obs, info = env.reset(seed=3)
        for _ in range(3000):
            self.assertEqual(obs.shape, (len(NAMES),))
            self.assertTrue(np.all(obs >= -1) and np.all(obs <= 1))
            self.assertTrue(info["valid"])
            self.assertTrue(all(ACTIONS[index][0] == info["chain"] for index in info["valid"]))
            obs, _, terminated, truncated, info = env.step(int(env.np_random.choice(info["valid"])))
            if terminated or truncated:
                obs, info = env.reset()

    def test_an_invalid_action_is_the_default_with_a_penalty(self):
        env = SquadEnv(fixed={"player": False, "order": None})
        env.reset(seed=1)
        self.assertNotIn(ACTIONS.index(("decision", "orders")), env.valid_actions())
        env.step(ACTIONS.index(("decision", "orders")))
        self.assertIn("decision:default", env.stats["actions"])

    def test_running_from_a_crowd_when_hurt_beats_fighting_it(self):
        crowd = {"player": False, "order": None, "health": 0.3, "weapon": "melee", "squad": 0,
                 "threat": {"kind": "zombie", "near": 8, "around": 12, "distance": 3.0}}
        _, after_fight = first_step(crowd, "default", "response")
        _, after_flee = first_step(crowd, "flee", "response")
        self.assertGreater(after_flee, after_fight)

    def test_a_lone_zombie_is_worth_fighting(self):
        lone = {"player": False, "order": None, "weapon": "melee", "threat": {"kind": "zombie", "near": 1,
                                                                             "around": 1, "distance": 2.0}}
        fight, _ = first_step(lone, "default", "response")
        flee, _ = first_step(lone, "flee", "response")
        self.assertGreater(fight, flee)

    def test_the_conversation_changes_what_pays(self):
        follow = {"player": True, "order": "follow", "player_distance": 10.0, "stance": "neutral"}
        trusted, _ = first_step(dict(follow, trust=0.9), "orders", "decision")
        distrusted, _ = first_step(dict(follow, trust=-0.9), "orders", "decision")
        self.assertGreater(trusted, distrusted, "following a trusted player pays more")
        close = {"player": True, "player_armed": True, "player_distance": 4.0, "stance": "careful", "trust": 0.0}
        afraid, _ = first_step(dict(close, fear=0.9), "careful", "decision")
        calm, _ = first_step(dict(close, fear=-0.5), "careful", "decision")
        self.assertGreater(afraid, calm, "warning a feared player off pays more")
        rob = {"player": True, "player_distance": 10.0, "stance": "hostile", "squad": 3}
        friendly, _ = first_step(dict(rob, trust=0.35), "robbery", "decision")
        foe, _ = first_step(dict(rob, trust=-0.35), "robbery", "decision")
        self.assertGreater(foe, friendly, "robbing someone it trusts is punished")

    def test_a_feared_player_fights_harder(self):
        powers = {}
        for fear in (0.9, -0.5):
            env = SquadEnv(fixed={"player": True, "player_armed": True, "fear": fear})
            env.reset(seed=0)
            powers[fear] = env._player_threat()["power"]
        self.assertGreater(powers[0.9], powers[-0.5])

    def test_goal_trades_safety_for_loot(self):
        quiet = {"player": False, "order": None}
        driven, _ = first_step(dict(quiet, goal=1.0), "scavenge", "decision")
        careful, _ = first_step(dict(quiet, goal=-1.0), "scavenge", "decision")
        self.assertGreater(driven, careful)


class PpoTests(unittest.TestCase):
    def test_trains_and_exports_a_net_the_game_reads_back(self):
        from alifebrain_rl import ppo

        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / "PolicyWeights.lua"
            self.assertEqual(ppo.main(["--timesteps", "2048", "--envs", "2", "--episodes", "3", "--out", str(out)]), 0)
            text = out.read_text(encoding="utf-8")
            self.assertIn("ppo.py", text.splitlines()[0])
            weights = parse_lua(text.split("ALifeBrain.PolicyWeights = ", 1)[1].rsplit("return ALifeBrain.PolicyWeights", 1)[0])
            self.assertEqual(weights["features"], NAMES)
            for chain, names in (("decision", DECISION_ACTIONS), ("response", RESPONSE_ACTIONS)):
                net = weights["nets"][chain]
                self.assertEqual(net["actions"], names)
                self.assertEqual(len(net["mean"]), len(NAMES))
                got = lua_logits(net, net["check"]["input"])
                for mine, stored in zip(got, net["check"]["logits"]):
                    self.assertTrue(math.isclose(mine, stored, abs_tol=1e-4))

    def test_the_actor_matches_stable_baselines(self):
        import torch
        from alifebrain_rl import ppo

        model = ppo.train(512, seed=3, n_envs=1)
        actor = ppo.Actor(*ppo.body(model))
        obs, _ = SquadEnv().reset(seed=4)
        with torch.no_grad():
            distribution = model.policy.get_distribution(torch.as_tensor(obs).reshape(1, -1))
            theirs = distribution.distribution.logits.numpy()[0]
        mine = actor.logits(obs)
        # SB3 stores log-probabilities (logits minus their log-sum-exp): compare after the same shift.
        mine = mine - np.log(np.exp(mine).sum())
        self.assertTrue(np.allclose(mine, theirs, atol=1e-5))


if __name__ == "__main__":
    unittest.main()
