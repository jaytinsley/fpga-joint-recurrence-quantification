"""Single-channel recurrence plot construction (blocked).

Ported from Li, Lai and Oberst (2026), Zenodo doi:10.5281/zenodo.20406392 (MIT).
The RTL compares squared distance against eps squared, and so does this code.
"""
from dataclasses import dataclass
from typing import Optional

import numpy as np

from .distance import max_pairwise_distance_blocked, sq_dist_block
from .embedding import takens_embedding


def recurrence_matrix_blocked(V, eps: float, block: int = 1024, xp=np) -> np.ndarray:
    """Return the n x n uint8 recurrence matrix on the host (NumPy)."""
    n = V.shape[0]
    R = np.empty((n, n), dtype=np.uint8)
    eps2 = eps * eps
    for i0 in range(0, n, block):
        i1 = min(i0 + block, n)
        Vi = V[i0:i1]
        for j0 in range(0, n, block):
            j1 = min(j0 + block, n)
            tile = (sq_dist_block(Vi, V[j0:j1], xp) <= eps2).astype(xp.uint8)
            R[i0:i1, j0:j1] = tile if xp is np else tile.get()
    return R


@dataclass(frozen=True)
class ChannelParams:
    """Embedding and threshold for one channel. Give exactly one of eps, eps_percent.

    eps_percent is a percentage of the maximum pairwise embedded distance of this
    channel (the Li et al. convention). eps is absolute, in signal units.
    """
    m: int
    tau: int
    eps: Optional[float] = None
    eps_percent: Optional[float] = None

    def __post_init__(self):
        if (self.eps is None) == (self.eps_percent is None):
            raise ValueError("give exactly one of eps, eps_percent")


def embed_pair(x, y, px: ChannelParams, py: ChannelParams, xp=np, align: str = "end"):
    """Embed both channels and align them in time.

    With different (m, tau) the embedded lengths differ, so both are cut to the
    shorter one. align="end" (default) pairs vectors that end on the same newest
    sample, which is what the RTL does: phase_space_reconstruction.v emits a vector
    as each sample arrives, once (m-1)*tau samples of history exist, so the joint
    state at time t is (x vector ending at t, y vector ending at t). align="start"
    pairs vectors that begin on the same sample. Identical when m and tau match.
    """
    if align not in ("end", "start"):
        raise ValueError("align must be 'end' or 'start'")
    x = xp.asarray(x, dtype=xp.float64)
    y = xp.asarray(y, dtype=xp.float64)
    if x.shape != y.shape:
        raise ValueError(f"channels must have equal length, got {x.shape} and {y.shape}")
    Vx = takens_embedding(x, px.m, px.tau, xp=xp)
    Vy = takens_embedding(y, py.m, py.tau, xp=xp)
    n = min(Vx.shape[0], Vy.shape[0])
    if align == "end":
        return Vx[Vx.shape[0] - n:], Vy[Vy.shape[0] - n:]
    return Vx[:n], Vy[:n]


def resolve_eps(V, p: ChannelParams, block: int = 1024, xp=np) -> float:
    if p.eps is not None:
        return float(p.eps)
    maxd = max_pairwise_distance_blocked(V, block=block, xp=xp)
    if not np.isfinite(maxd) or maxd <= 0:
        raise ValueError(f"invalid max distance {maxd}")
    return max((p.eps_percent / 100.0) * maxd, np.finfo(np.float64).tiny)


def joint_recurrence_blocked(x, y, px: ChannelParams, py: ChannelParams,
                             block: int = 1024, xp=np, align: str = "end"):
    """Joint recurrence plot JR(i,j) = Theta(eps_x - ||x_i - x_j||) * Theta(eps_y - ||y_i - y_j||).

    x and y are equal-length 1-D signals, already normalised as the caller wants.
    Each channel has its own m, tau and eps. Distances are Euclidean, evaluated in
    block x block tiles (Gram identity) and compared as squared distance against
    eps squared, as the RTL does. Only one pair of tiles is on the device at a time.
    Returns (JR, info): JR is an n x n uint8 NumPy array, info holds n, eps_x, eps_y.
    """
    Vx, Vy = embed_pair(x, y, px, py, xp=xp, align=align)
    eps_x = resolve_eps(Vx, px, block, xp)
    eps_y = resolve_eps(Vy, py, block, xp)
    JR = joint_recurrence_from_embedded(Vx, Vy, eps_x, eps_y, block=block, xp=xp)
    return JR, {"n": Vx.shape[0], "eps_x": eps_x, "eps_y": eps_y}


def joint_recurrence_from_embedded(Vx, Vy, eps_x: float, eps_y: float, block: int = 1024, xp=np):
    """The compare stage alone: tiled squared distances against eps squared, per channel,
    AND-ed. Vx and Vy are equal-length embedded matrices on the backend device. Returns
    the n x n uint8 matrix on the host."""
    n = Vx.shape[0]
    ex2, ey2 = eps_x * eps_x, eps_y * eps_y
    JR = np.empty((n, n), dtype=np.uint8)
    for i0 in range(0, n, block):
        i1 = min(i0 + block, n)
        for j0 in range(0, n, block):
            j1 = min(j0 + block, n)
            rx = sq_dist_block(Vx[i0:i1], Vx[j0:j1], xp) <= ex2
            ry = sq_dist_block(Vy[i0:i1], Vy[j0:j1], xp) <= ey2
            tile = (rx & ry).astype(xp.uint8)
            JR[i0:i1, j0:j1] = tile if xp is np else tile.get()
    return JR
