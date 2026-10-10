"""A small numpy MLP policy: tanh hidden layers, one logit per action, softmax over the
actions an NPC is allowed to take. Same shape as Stable-Baselines3's default MlpPolicy
actor (64-64 tanh), so phase 4 (PPO) can start from these weights. Policy.lua runs the
same forward pass in the game."""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

MASKED = -1e9


class MLP:
    def __init__(self, sizes: list[int], rng: np.random.Generator) -> None:
        self.sizes = sizes
        self.weights: list[np.ndarray] = []  # (inputs, outputs)
        self.biases: list[np.ndarray] = []
        last = len(sizes) - 2
        for layer, (fan_in, fan_out) in enumerate(zip(sizes[:-1], sizes[1:])):
            limit = np.sqrt(6.0 / (fan_in + fan_out))
            scale = 0.01 if layer == last else 1.0  # small output layer: near-uniform choices at the start
            self.weights.append(rng.uniform(-limit, limit, (fan_in, fan_out)) * scale)
            self.biases.append(np.zeros(fan_out))

    @property
    def params(self) -> list[np.ndarray]:
        return [p for pair in zip(self.weights, self.biases) for p in pair]

    def set_params(self, params: list[np.ndarray]) -> None:
        self.weights = [p.copy() for p in params[0::2]]
        self.biases = [p.copy() for p in params[1::2]]

    def forward(self, x: np.ndarray) -> tuple[np.ndarray, list[np.ndarray]]:
        activations = [x]
        for layer, (weight, bias) in enumerate(zip(self.weights, self.biases)):
            x = x @ weight + bias
            if layer < len(self.weights) - 1:
                x = np.tanh(x)
            activations.append(x)
        return x, activations

    def backward(self, activations: list[np.ndarray], grad: np.ndarray) -> list[np.ndarray]:
        grads: list[np.ndarray] = []
        for layer in range(len(self.weights) - 1, -1, -1):
            inputs = activations[layer]
            grads = [inputs.T @ grad, grad.sum(axis=0)] + grads
            if layer > 0:
                grad = (grad @ self.weights[layer].T) * (1.0 - activations[layer] ** 2)
        return grads


def masked_softmax(logits: np.ndarray, masks: np.ndarray) -> np.ndarray:
    z = np.where(masks, logits, MASKED)
    z = z - z.max(axis=1, keepdims=True)
    e = np.exp(z) * masks
    return e / e.sum(axis=1, keepdims=True)


def loss_and_grad(logits: np.ndarray, labels: np.ndarray, masks: np.ndarray,
                  weights: np.ndarray) -> tuple[float, np.ndarray]:
    """Weighted cross-entropy over the allowed actions only."""
    probs = masked_softmax(logits, masks)
    rows = np.arange(len(labels))
    total = weights.sum()
    loss = float(-(weights * np.log(probs[rows, labels] + 1e-12)).sum() / total)
    grad = probs.copy()
    grad[rows, labels] -= 1.0
    return loss, grad * (weights / total)[:, None]


def predict(model: MLP, x: np.ndarray, masks: np.ndarray) -> np.ndarray:
    logits, _ = model.forward(x)
    return np.where(masks, logits, MASKED).argmax(axis=1)


@dataclass
class Adam:
    lr: float = 1e-3
    beta1: float = 0.9
    beta2: float = 0.999
    eps: float = 1e-8
    weight_decay: float = 1e-4
    t: int = 0
    m: list[np.ndarray] = field(default_factory=list)
    v: list[np.ndarray] = field(default_factory=list)

    def step(self, params: list[np.ndarray], grads: list[np.ndarray]) -> None:
        if not self.m:
            self.m = [np.zeros_like(p) for p in params]
            self.v = [np.zeros_like(p) for p in params]
        self.t += 1
        for index, (param, grad) in enumerate(zip(params, grads)):
            if param.ndim > 1:
                grad = grad + self.weight_decay * param
            self.m[index] = self.beta1 * self.m[index] + (1 - self.beta1) * grad
            self.v[index] = self.beta2 * self.v[index] + (1 - self.beta2) * grad * grad
            m_hat = self.m[index] / (1 - self.beta1 ** self.t)
            v_hat = self.v[index] / (1 - self.beta2 ** self.t)
            param -= self.lr * m_hat / (np.sqrt(v_hat) + self.eps)


def train(model: MLP, train_set: tuple, val_set: tuple, *, epochs: int, batch_size: int, lr: float,
          patience: int, rng: np.random.Generator, log=None) -> dict:
    """Minibatch Adam; keeps the parameters with the best validation loss. Sets are
    (x, labels, masks, weights). Returns the training history."""
    x, labels, masks, weights = train_set
    vx, vlabels, vmasks, vweights = val_set
    optimizer = Adam(lr=lr)
    best_loss, best_params, best_epoch, waited = np.inf, [p.copy() for p in model.params], 0, 0
    history = {"train": [], "val": []}
    for epoch in range(1, epochs + 1):
        order = rng.permutation(len(labels))
        epoch_loss = 0.0
        for start in range(0, len(order), batch_size):
            batch = order[start:start + batch_size]
            logits, activations = model.forward(x[batch])
            loss, grad = loss_and_grad(logits, labels[batch], masks[batch], weights[batch])
            params = model.params
            optimizer.step(params, model.backward(activations, grad))
            epoch_loss += loss * len(batch)
        val_logits, _ = model.forward(vx)
        val_loss, _ = loss_and_grad(val_logits, vlabels, vmasks, vweights)
        history["train"].append(epoch_loss / len(order))
        history["val"].append(val_loss)
        if val_loss < best_loss - 1e-5:
            best_loss, best_params, best_epoch, waited = val_loss, [p.copy() for p in model.params], epoch, 0
        else:
            waited += 1
        if log is not None and (epoch == 1 or epoch % 10 == 0):
            log(f"  epoch {epoch:3d}  train {history['train'][-1]:.4f}  val {val_loss:.4f}")
        if waited >= patience:
            break
    model.set_params(best_params)
    history["best_epoch"] = best_epoch
    history["best_val"] = float(best_loss)
    return history
