"""PPO (phase 4): trains the policy in the squad simulation (sim.py) with Stable-Baselines3 and
writes it in the game's format: two nets (the decision chain's actions and the response
chain's) sharing one 64-64 tanh body, as Policy.lua runs them.

    rl\\run-ppo.cmd              3M steps (~20 min on CPU) -> rl\\out\\PolicyWeights.ppo.lua
    rl\\run-ppo.cmd --install    ...and into the mod (the game's shadow mode)

It reports, for the trained policy and two baselines (an A-Life-like rule of thumb and random
choices), the mean return, deaths and squad losses over fresh episodes, and how the choice
moves with trust, fear and goal - the knobs the conversation turns.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np

from .bc import DEFAULT_OUT
from .export import write_weights
from .features import NAMES, SCHEMA
from .sim import ACTIONS, DECISION_ACTIONS, RESPONSE_ACTIONS, SCAVENGE, SquadEnv

OUT = Path(__file__).resolve().parents[1] / "out" / "PolicyWeights.ppo.lua"
CHAINS = (("decision", DECISION_ACTIONS), ("response", RESPONSE_ACTIONS))


def train(timesteps: int, seed: int, n_envs: int = 8):
    import torch
    from stable_baselines3 import PPO
    from stable_baselines3.common.env_util import make_vec_env

    from stable_baselines3.common.vec_env import VecNormalize

    # Rewards scaled to a steady size (deaths are rare, large spikes); observations stay raw, as
    # the game feeds them, so nothing extra is needed to run the exported net.
    env = VecNormalize(make_vec_env(SquadEnv, n_envs=n_envs, seed=seed), norm_obs=False, norm_reward=True, gamma=0.98)
    # Big batches and a KL stop: rare moments (a feared player close by) need steady updates, and
    # smaller ones let some seeds collapse into "scavenge everywhere".
    model = PPO("MlpPolicy", env, seed=seed, n_steps=1024, batch_size=512, gamma=0.98, ent_coef=0.01,
                learning_rate=3e-4, target_kl=0.02, verbose=0, device="cpu",
                policy_kwargs={"net_arch": {"pi": [64, 64], "vf": [64, 64]}, "activation_fn": torch.nn.Tanh})
    model.learn(total_timesteps=timesteps)
    return model


def body(model) -> tuple[list[dict], np.ndarray, np.ndarray]:
    """The actor as plain arrays: hidden layers (rows per output unit) and the action head."""
    import torch

    linears = [module for module in model.policy.mlp_extractor.policy_net if isinstance(module, torch.nn.Linear)]
    layers = [{"w": layer.weight.detach().numpy().astype(float), "b": layer.bias.detach().numpy().astype(float),
               "act": "tanh"} for layer in linears]
    head = model.policy.action_net
    return layers, head.weight.detach().numpy().astype(float), head.bias.detach().numpy().astype(float)


def forward(layers: list[dict], x: np.ndarray) -> np.ndarray:
    """Policy.logits (mean 0, std 1: the features are already scaled)."""
    for layer in layers:
        x = np.asarray(layer["w"]) @ x + np.asarray(layer["b"])
        if layer["act"] == "tanh":
            x = np.tanh(x)
    return x


class Actor:
    """The trained policy as the game will run it: logits from the arrays, masked choice."""

    def __init__(self, layers: list[dict], head_w: np.ndarray, head_b: np.ndarray) -> None:
        self.layers = layers + [{"w": head_w, "b": head_b, "act": "linear"}]

    def logits(self, obs: np.ndarray) -> np.ndarray:
        return forward(self.layers, np.asarray(obs, dtype=float))

    def __call__(self, env: SquadEnv, obs: np.ndarray, info: dict) -> int:
        scores = self.logits(obs)
        valid = info["valid"]
        return max(valid, key=lambda index: scores[index])


def alife_like(env: SquadEnv, obs: np.ndarray, info: dict) -> int:
    """A rule of thumb close to A-Life's own: follow orders, else patrol; fight, unless badly
    hurt (A-Life's flee module)."""
    valid = {ACTIONS[index]: index for index in info["valid"]}
    if info["chain"] == "decision":
        return valid.get(("decision", "orders"), valid.get(("decision", "patrolRest"), info["valid"][0]))
    if env.health <= 0.35 and ("response", "flee") in valid:
        return valid[("response", "flee")]
    return valid[("response", "default")]


def random_choice(env: SquadEnv, obs: np.ndarray, info: dict) -> int:
    return int(env.np_random.choice(info["valid"]))


def evaluate(policy, episodes: int, seed: int) -> dict:
    env = SquadEnv()
    results = {"return": [], "died": [], "mates_lost": [], "task": []}
    for episode in range(episodes):
        obs, info = env.reset(seed=seed + episode)
        done = False
        while not done:
            obs, _, terminated, truncated, info = env.step(policy(env, obs, info))
            done = terminated or truncated
        for key in results:
            results[key].append(float(env.stats[key]))
    return {key: float(np.mean(values)) for key, values in results.items()}


# Situations where the conversation should change the choice: (label, fixed start, variants).
PROBES = [
    ("asked to follow", {"player": True, "order": "follow", "player_distance": 10.0, "stance": "neutral", "squad": 1},
     [("trust +0.9", {"trust": 0.9}), ("trust -0.9", {"trust": -0.9})]),
    ("armed player close", {"player": True, "player_armed": True, "player_distance": 4.0, "stance": "careful",
                            "trust": 0.0, "order": None},
     [("fear +0.9", {"fear": 0.9}), ("fear -0.5", {"fear": -0.5})]),
    ("quiet, nobody around", {"player": False, "order": None, "health": 1.0},
     [("goal +1", {"goal": 1.0}), ("goal -1", {"goal": -1.0})]),
    ("8 zombies on it", {"player": False, "order": None, "threat": {"kind": "zombie", "near": 8, "around": 12,
                                                                     "distance": 3.0}},
     [("healthy", {"health": 1.0}), ("hurt (0.3)", {"health": 0.3})]),
]


def probe(policy, fixed: dict, runs: int = 200, seed: int = 10_000) -> dict[str, float]:
    """Share of each first choice over runs fresh starts with fixed pinned."""
    env = SquadEnv(fixed=fixed)
    counts: dict[str, int] = {}
    for run in range(runs):
        obs, info = env.reset(seed=seed + run)
        name = ACTIONS[policy(env, obs, info)][1]
        counts[name] = counts.get(name, 0) + 1
    return {name: count / runs for name, count in sorted(counts.items(), key=lambda item: -item[1])}


def _close_armed(env: SquadEnv) -> bool:
    return (env.order is None and env.player_present and env.player_armed and env.player_distance < 10
            and "careful" in env.valid_names())


def _quiet(env: SquadEnv) -> bool:
    return env.order is None and not (env.player_present and env.player_distance < 10)


def _hard_crowd(env: SquadEnv) -> bool:
    return env.threat["kind"] == "zombie" and env.threat["near"] >= 4


# Habits over whole episodes: (label, chain, situation, chosen actions, [(variant, condition), ...]).
HABITS = [
    ("follows when asked", "decision", lambda env: env.order == "follow", {"orders"},
     [("trust > +0.6", lambda env: env.trust > 0.6), ("trust < +0.4", lambda env: env.trust < 0.4)]),
    ("warns off an armed player (< 10 tiles)", "decision", _close_armed, {"careful"},
     [("fear > +0.5", lambda env: env.fear > 0.5), ("fear < 0", lambda env: env.fear < 0)]),
    ("scavenges when alone", "decision", _quiet, SCAVENGE,
     [("goal > +0.5", lambda env: env.goal > 0.5), ("goal < -0.5", lambda env: env.goal < -0.5)]),
    ("runs from 4+ zombies", "response", _hard_crowd, {"flee", "panic", "alifeBrainCompanion"},
     [("health < 0.4", lambda env: env.health < 0.4), ("health > 0.8", lambda env: env.health > 0.8)]),
]


def habits(policy, episodes: int, seed: int) -> list[tuple[str, str, float, int]]:
    """For each habit and variant: how often the policy picked those actions there, and how often it came up."""
    counts = {(label, variant): [0, 0] for label, _, _, _, variants in HABITS for variant, _ in variants}
    env = SquadEnv()
    for episode in range(episodes):
        obs, info = env.reset(seed=seed + episode)
        done = False
        while not done:
            action = policy(env, obs, info)
            for label, chain, situation, chosen, variants in HABITS:
                if info["chain"] != chain or not situation(env):
                    continue
                for variant, condition in variants:
                    if condition(env):
                        counts[(label, variant)][0] += ACTIONS[action][1] in chosen
                        counts[(label, variant)][1] += 1
            obs, _, terminated, truncated, info = env.step(action)
            done = terminated or truncated
    return [(label, variant, hits / seen if seen else float("nan"), seen)
            for (label, variant), (hits, seen) in counts.items()]


def check_inputs(actor: Actor, seed: int) -> dict[str, np.ndarray]:
    """For each chain, a simulated observation whose logits spread the most."""
    env = SquadEnv()
    best: dict[str, tuple[float, np.ndarray]] = {}
    obs, info = env.reset(seed=seed)
    for _ in range(2000):
        chain = info["chain"]
        rows = [index for index, (c, _) in enumerate(ACTIONS) if c == chain]
        scores = actor.logits(obs)[rows]
        spread = float(scores.max() - scores.min())
        if chain not in best or spread > best[chain][0]:
            best[chain] = (spread, obs.astype(float))
        obs, _, terminated, truncated, info = env.step(actor(env, obs, info))
        if terminated or truncated:
            obs, info = env.reset()
    return {chain: value[1] for chain, value in best.items()}


def nets_for(layers: list[dict], head_w: np.ndarray, head_b: np.ndarray, checks: dict, metrics: dict) -> dict:
    nets = {}
    for chain, names in CHAINS:
        rows = [index for index, (c, _) in enumerate(ACTIONS) if c == chain]
        net_layers = layers + [{"w": head_w[rows], "b": head_b[rows], "act": "linear"}]
        check = checks.get(chain, np.zeros(len(NAMES)))
        nets[chain] = {"actions": list(names), "mean": np.zeros(len(NAMES)), "std": np.ones(len(NAMES)),
                       "layers": net_layers, "check": {"input": check, "logits": forward(net_layers, check)},
                       "metrics": metrics}
    return nets


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="alifebrain_rl.ppo", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--timesteps", type=int, default=3_000_000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--envs", type=int, default=8)
    parser.add_argument("--episodes", type=int, default=200, help="fresh episodes for the comparison")
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--install", action="store_true", help="also write it into the mod (PolicyWeights.lua)")
    args = parser.parse_args(argv)

    def log(message: str) -> None:
        print(message, flush=True)

    started = time.time()
    log(f"training PPO for {args.timesteps} steps in {args.envs} simulated squads ...")
    model = train(args.timesteps, args.seed, args.envs)
    log(f"  done in {time.time() - started:.0f} s")
    layers, head_w, head_b = body(model)
    actor = Actor(layers, head_w, head_b)

    log(f"\n{'policy':<12}{'return':>9}{'died':>8}{'mates lost':>12}{'task':>8}   ({args.episodes} fresh episodes)")
    results = {}
    for label, policy in (("ppo", actor), ("a-life-like", alife_like), ("random", random_choice)):
        results[label] = evaluate(policy, args.episodes, seed=1_000_000)
        r = results[label]
        log(f"{label:<12}{r['return']:>9.2f}{r['died']:>8.0%}{r['mates_lost']:>12.2f}{r['task']:>8.2f}")

    log("\nhow the conversation moves the first choice (share over 200 starts):")
    for label, fixed, variants in PROBES:
        for variant, extra in variants:
            shares = probe(actor, dict(fixed, **extra))
            top = ", ".join(f"{name} {share:.0%}" for name, share in list(shares.items())[:3])
            log(f"  {label:<22} {variant:<12} {top}")

    log(f"\nhabits over {args.episodes} fresh episodes (share of those moments; a-life-like in brackets):")
    rule = {(label, variant): share for label, variant, share, _ in habits(alife_like, args.episodes, 2_000_000)}
    for label, variant, share, seen in habits(actor, args.episodes, 2_000_000):
        log(f"  {label:<40} {variant:<13} {share:>5.0%} [{rule[(label, variant)]:.0%}]  of {seen}")

    metrics ={"trainer": "ppo", "timesteps": args.timesteps, "return": round(results["ppo"]["return"], 3),
               "baseline": round(results["a-life-like"]["return"], 3), "died": round(results["ppo"]["died"], 3)}
    nets = nets_for(layers, head_w, head_b, check_inputs(actor, args.seed), metrics)
    created = time.strftime("%Y-%m-%d %H:%M")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    source = "rl/alifebrain_rl/ppo.py (PPO in the squad simulation)"
    write_weights(args.out, schema=SCHEMA, nets=nets, created=created, names=NAMES, source=source)
    log(f"\nwrote {args.out}")
    if args.install:
        write_weights(DEFAULT_OUT, schema=SCHEMA, nets=nets, created=created, names=NAMES, source=source)
        log(f"installed in {DEFAULT_OUT}; restart the game (shadow mode: ALifeBrain.policy())")
    return 0


if __name__ == "__main__":
    sys.exit(main())
