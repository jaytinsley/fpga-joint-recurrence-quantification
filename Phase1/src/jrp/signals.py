"""Benchmark signal generators, all normalised to [0, 1].

Ported unchanged from Li, Lai and Oberst (2026), scripts/python_rp_vs_fpga.ipynb,
Zenodo doi:10.5281/zenodo.20406392 (MIT licence).
"""
import math
from typing import Tuple

import numpy as np


def to_unit_interval(x: np.ndarray) -> np.ndarray:
    x = np.asarray(x, dtype=np.float64)
    xmin, xmax = np.min(x), np.max(x)
    if xmax == xmin:
        return np.zeros_like(x)
    return (x - xmin) / (xmax - xmin)


def gen_uwn(N: int, seed: int = 42) -> np.ndarray:
    rng = np.random.default_rng(seed)
    x = rng.random(N, dtype=np.float64)
    return to_unit_interval(x)


def gen_logistic(N: int, r: float = 3.82843, x0: float = 0.5, burn_in: int = 100) -> np.ndarray:
    x = np.empty(N + burn_in, dtype=np.float64)
    x[0] = x0
    for i in range(1, N + burn_in):
        x[i] = r * x[i - 1] * (1.0 - x[i - 1])
    x = x[burn_in:]
    return to_unit_interval(x)


def lorenz_step(x, y, z, sigma=10.0, b=8.0 / 3.0, r=28.0):
    dx = sigma * (y - x)
    dy = x * (r - z) - y
    dz = x * y - b * z
    return dx, dy, dz


def integrate_lorenz(total_time: float = 100.0, dt: float = 0.1,
                     sigma=10.0, b=8.0 / 3.0, r=28.0,
                     init=(1.0, 1.0, 1.0)) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """RK4 integration of the Lorenz system. Returns t, x, y, z."""
    steps = int(math.ceil(total_time / dt)) + 1
    t = np.linspace(0.0, total_time, steps, dtype=np.float64)
    x = np.empty(steps, dtype=np.float64)
    y = np.empty(steps, dtype=np.float64)
    z = np.empty(steps, dtype=np.float64)
    x[0], y[0], z[0] = init
    for i in range(1, steps):
        xi, yi, zi = x[i - 1], y[i - 1], z[i - 1]
        k1x, k1y, k1z = lorenz_step(xi, yi, zi, sigma, b, r)
        k2x, k2y, k2z = lorenz_step(xi + 0.5 * dt * k1x, yi + 0.5 * dt * k1y, zi + 0.5 * dt * k1z, sigma, b, r)
        k3x, k3y, k3z = lorenz_step(xi + 0.5 * dt * k2x, yi + 0.5 * dt * k2y, zi + 0.5 * dt * k2z, sigma, b, r)
        k4x, k4y, k4z = lorenz_step(xi + dt * k3x, yi + dt * k3y, zi + dt * k3z, sigma, b, r)
        x[i] = xi + (dt / 6.0) * (k1x + 2 * k2x + 2 * k3x + k4x)
        y[i] = yi + (dt / 6.0) * (k1y + 2 * k2y + 2 * k3y + k4y)
        z[i] = zi + (dt / 6.0) * (k1z + 2 * k2z + 2 * k3z + k4z)
    return t, x, y, z


def resample_to_length(t: np.ndarray, x: np.ndarray, N: int, total_time: float) -> np.ndarray:
    t_target = np.linspace(0.0, total_time, N, dtype=np.float64)
    return np.interp(t_target, t, x).astype(np.float64, copy=False)


def gen_lorenz_x_resampled(N: int, total_time: float = 100.0, dt_sim: float = 0.1,
                           sigma=10.0, b=8.0 / 3.0, r=28.0, init=(1.0, 1.0, 1.0)) -> np.ndarray:
    t, x, y, z = integrate_lorenz(total_time=total_time, dt=dt_sim,
                                  sigma=sigma, b=b, r=r, init=init)
    return to_unit_interval(resample_to_length(t, x, N, total_time))


def gen_harmonic_5_osc(N: int, total_time: float = 100.0, cycles: int = 5) -> np.ndarray:
    t = np.linspace(0.0, total_time, N, dtype=np.float64)
    return to_unit_interval(np.sin(2.0 * np.pi * cycles * (t / total_time)))


def gen_coupled_logistic(N: int, c: float, r: float = 3.82843, x0: float = 0.3,
                         y0: float = 0.7, burn_in: int = 100, mode: str = "mutual"):
    """Two logistic maps with diffusive coupling c in [0, 1], f(u) = r u (1 - u).

    mode "mutual": x' = (1 - c) f(x) + c f(y),  y' = (1 - c) f(y) + c f(x).
    mode "drive":  x' = f(x),  y' = (1 - c) f(y) + c f(x)   (x drives y, one way).
    c = 0 gives independent maps; the pair synchronises as c grows. Both outputs stay
    in [0, 1] (convex combination of values of f) and are normalised to [0, 1] here.
    Not from Li et al.; same r and burn-in as their single-channel logistic generator.
    Chaotic: store the returned samples, do not regenerate them on another platform.
    """
    if mode not in ("mutual", "drive"):
        raise ValueError("mode must be 'mutual' or 'drive'")
    x = np.empty(N + burn_in, dtype=np.float64)
    y = np.empty(N + burn_in, dtype=np.float64)
    x[0], y[0] = x0, y0
    for i in range(1, N + burn_in):
        fx = r * x[i - 1] * (1.0 - x[i - 1])
        fy = r * y[i - 1] * (1.0 - y[i - 1])
        x[i] = (1.0 - c) * fx + c * fy if mode == "mutual" else fx
        y[i] = (1.0 - c) * fy + c * fx
    return to_unit_interval(x[burn_in:]), to_unit_interval(y[burn_in:])
