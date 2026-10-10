"""Behavior cloning (phase 3): learns to choose what A-Life chose, from the decisions the
game logged, and writes the networks into the mod (PolicyWeights.lua).

    rl\\run-bc.cmd                       (or: python -m alifebrain_rl.bc)
    rl\\run-bc.cmd --dry-run             train and report, write nothing
    rl\\run-bc.cmd --data D:\\some\\dataset --out weights.lua

One network per A-Life chain: "decision" (no threat) and "response" (a threat). The
validation set holds out whole NPCs, so the score is for NPCs the model never saw.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np

from .data import DEFAULT, Dataset, default_dir, load
from .export import net_table, write_weights
from .mlp import MLP, predict, train

DISPATCHES = ("decision", "response")
DEFAULT_OUT = (Path(__file__).resolve().parents[2] / "mod" / "Contents" / "mods" / "ALifeBrain" / "42" / "media"
               / "lua" / "shared" / "ALifeBrain" / "PolicyWeights.lua")


def split(dataset: Dataset, rng: np.random.Generator, fraction: float = 0.2) -> tuple[np.ndarray, np.ndarray]:
    """Train / validation row indices: whole NPCs held out when there are enough of them,
    otherwise the newest rows."""
    groups = np.unique(dataset.groups)
    if len(groups) >= 5:
        held = rng.choice(groups, size=max(1, int(round(len(groups) * fraction))), replace=False)
        val = np.isin(dataset.groups, held)
    else:
        order = np.argsort(dataset.ts, kind="stable")
        val = np.zeros(len(dataset), dtype=bool)
        val[order[int(len(order) * (1 - fraction)):]] = True
    return np.flatnonzero(~val), np.flatnonzero(val)


def class_weights(labels: np.ndarray, count: int) -> np.ndarray:
    """1 / sqrt(frequency), normalised to mean 1 over the samples: rare choices still count
    without drowning the common ones."""
    frequency = np.bincount(labels, minlength=count).astype(float)
    weight = np.zeros(count)
    seen = frequency > 0
    weight[seen] = 1.0 / np.sqrt(frequency[seen])
    per_sample = weight[labels]
    return weight / per_sample.mean()


def evaluate(model: MLP, x: np.ndarray, labels: np.ndarray, masks: np.ndarray, actions: list[str],
             majority: int) -> dict:
    chosen = predict(model, x, masks)
    baseline = np.where(masks[:, majority], majority, actions.index(DEFAULT))
    recall = {}
    for index, action in enumerate(actions):
        support = labels == index
        if support.any():
            recall[action] = {"n": int(support.sum()), "recall": round(float((chosen[support] == index).mean()), 3)}
    return {"accuracy": round(float((chosen == labels).mean()), 4),
            "baseline": round(float((baseline == labels).mean()), 4), "recall": recall}


def train_dispatch(dataset: Dataset, *, hidden: list[int], epochs: int, seed: int, log) -> tuple[dict, dict]:
    rng = np.random.default_rng(seed)
    train_rows, val_rows = split(dataset, rng)
    x, labels, masks = dataset.obs.astype(np.float64), dataset.labels, dataset.masks
    mean = x[train_rows].mean(axis=0)
    std = x[train_rows].std(axis=0)
    std[std < 1e-6] = 1.0
    z = (x - mean) / std
    weights = class_weights(labels[train_rows], len(dataset.actions))
    model = MLP([z.shape[1], *hidden, len(dataset.actions)], rng)
    history = train(model, (z[train_rows], labels[train_rows], masks[train_rows], weights[labels[train_rows]]),
                    (z[val_rows], labels[val_rows], masks[val_rows], weights[labels[val_rows]]),
                    epochs=epochs, batch_size=256, lr=1e-3, patience=10, rng=rng, log=log)
    majority = int(np.bincount(labels[train_rows], minlength=len(dataset.actions)).argmax())
    report = evaluate(model, z[val_rows], labels[val_rows], masks[val_rows], dataset.actions, majority)
    report.update({"samples": len(dataset), "train": int(len(train_rows)), "validation": int(len(val_rows)),
                   "npcs": int(len(np.unique(dataset.groups))), "best_epoch": history["best_epoch"]})
    metrics = {key: report[key] for key in ("accuracy", "baseline", "samples", "npcs")}
    table = net_table(model, actions=dataset.actions, mean=mean, std=std, check_input=check_input(model, x, z, val_rows),
                      metrics=metrics)
    return table, report


def check_input(model: MLP, x: np.ndarray, z: np.ndarray, rows: np.ndarray) -> np.ndarray:
    """The raw input whose logits spread the most: the game's recomputation of it only
    proves something when the numbers are not all near zero."""
    candidates = rows[:256] if len(rows) else np.arange(min(len(x), 256))
    logits, _ = model.forward(z[candidates])
    return x[candidates[int(np.argmax(logits.max(axis=1) - logits.min(axis=1)))]]


def print_report(dispatch: str, dataset: Dataset, report: dict, log) -> None:
    log(f"{dispatch}: {report['samples']} decisions from {report['npcs']} NPCs, {len(dataset.actions)} actions")
    log(f"  validation accuracy {report['accuracy']:.1%} (always picking the most common choice: "
        f"{report['baseline']:.1%}), best epoch {report['best_epoch']}")
    for action, entry in sorted(report["recall"].items(), key=lambda item: -item[1]["n"]):
        log(f"    {action:<16} n={entry['n']:<6} recall {entry['recall']:.0%}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="alifebrain_rl.bc", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", type=Path, default=default_dir(), help="dataset folder (the sidecar's)")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="PolicyWeights.lua to write")
    parser.add_argument("--hidden", default="64,64", help="hidden layer sizes, e.g. 64,64")
    parser.add_argument("--epochs", type=int, default=120)
    parser.add_argument("--min-samples", type=int, default=300, help="skip a chain with fewer decisions")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--exclude", action="append", default=[], metavar="ACTION",
                        help="leave out decisions with this label (repeatable), e.g. alifeBrainStandoff")
    parser.add_argument("--dry-run", action="store_true", help="train and report only")
    args = parser.parse_args(argv)

    def log(message: str) -> None:
        print(message, flush=True)

    hidden = [int(size) for size in args.hidden.split(",") if size.strip()]
    nets, names, schema = {}, None, None
    for dispatch in DISPATCHES:
        dataset = load(args.data, dispatch, exclude=frozenset(args.exclude))
        if dataset is None:
            log(f"{dispatch}: no decisions in {args.data}")
            continue
        if len(dataset) < args.min_samples:
            log(f"{dispatch}: only {len(dataset)} decisions (need {args.min_samples}); play longer with the sidecar on")
            continue
        log(f"{dispatch}: training on {len(dataset)} decisions ...")
        table, report = train_dispatch(dataset, hidden=hidden, epochs=args.epochs, seed=args.seed, log=log)
        print_report(dispatch, dataset, report, log)
        nets[dispatch], names, schema = table, dataset.names, dataset.schema
    if not nets:
        log("nothing trained")
        return 1
    if args.dry_run:
        log("dry run: nothing written")
        return 0
    created = time.strftime("%Y-%m-%d %H:%M")
    write_weights(args.out, schema=schema, nets=nets, created=created, names=names)
    log(f"wrote {args.out}; restart the game to load it (shadow mode: ALifeBrain.policy() in the debug console)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
