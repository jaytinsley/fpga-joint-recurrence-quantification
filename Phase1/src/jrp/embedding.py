"""Time-delay (Takens) embedding.

Ported from Li, Lai and Oberst (2026), Zenodo doi:10.5281/zenodo.20406392 (MIT).
"""
import numpy as np


def takens_embedding(x, m: int, tau: int, xp=np, dtype=np.float64):
    """Return the (N - (m-1)*tau, m) delay-embedded matrix of x (float64 unless dtype given).

    Column k holds x[i + k*tau], so the newest sample of each vector is in column m-1.
    The RTL (phase_space_reconstruction.v) orders components the other way round,
    newest first; distances do not depend on component order.
    """
    x = xp.asarray(x, dtype=dtype)
    N = x.shape[0]
    N_eff = N - (m - 1) * tau
    if N_eff <= 0:
        raise ValueError("Effective length <= 0; increase N or decrease m/tau.")
    V = xp.empty((N_eff, m), dtype=dtype)
    for k in range(m):
        V[:, k] = x[k * tau: k * tau + N_eff]
    return V


# ---- Embedding parameter selection: average mutual information (tau), false nearest
# ---- neighbours (m). Thin wrappers over nolitsa (Mannattil), float64, CPU.

def ami(x, maxtau: int = 100, bins: int = 32):
    """Average mutual information I(x_t; x_{t+tau}) in bits for tau = 0 .. maxtau-1.

    Histogram estimator (nolitsa.delay.dmi). 32 bins is used rather than nolitsa's 64:
    at N = 4096 a 64 x 64 joint histogram is bias-dominated (white noise already scores
    about 0.8 bits), which hides the minimum.
    """
    from nolitsa import delay
    x = np.asarray(x, dtype=np.float64)
    return np.asarray(delay.dmi(x, maxtau=maxtau, bins=bins), dtype=np.float64)


def first_local_minimum(curve, smooth: int = 1) -> int:
    """Index of the first strict local minimum of a 1-D curve, or -1 if there is none.

    smooth is the width of a centred moving average applied first (1 = none).
    """
    c = np.asarray(curve, dtype=np.float64)
    if smooth > 1:
        c = np.convolve(np.pad(c, smooth // 2, mode="edge"), np.ones(smooth) / smooth, mode="valid")
    for k in range(1, len(c) - 1):
        if c[k - 1] > c[k] <= c[k + 1] and c[k] < c[k - 1]:
            return k
    return -1


def select_tau(x, maxtau: int = 100, bins: int = 32, smooth: int = 1) -> int:
    """Delay (in samples) at the first local minimum of the AMI curve. Falls back to the
    global minimum of the curve if there is no interior minimum."""
    mi = ami(x, maxtau=maxtau, bins=bins)
    k = first_local_minimum(mi, smooth=smooth)
    return int(k if k > 0 else np.argmin(mi[1:]) + 1)


def fnn_fractions(x, tau: int, dims=range(1, 11), R: float = 10.0, A: float = 2.0,
                  window: int = 10):
    """Fraction of false nearest neighbours (Kennel et al. 1992) for each dimension.

    Returns an array aligned with dims. A neighbour is false if it fails the distance-ratio
    test (R) or the attractor-size test (A). window is the Theiler window in samples.
    """
    from nolitsa import dimension
    x = np.asarray(x, dtype=np.float64)
    dims = list(dims)
    _, _, either = dimension.fnn(x, dim=dims, tau=tau, R=R, A=A, window=window, parallel=False)
    return np.asarray(either, dtype=np.float64)


def select_dim(x, tau: int, max_dim: int = 10, threshold: float = 0.05, **kw) -> int:
    """Smallest embedding dimension whose false-neighbour fraction is below threshold.
    Returns max_dim if none is."""
    dims = list(range(1, max_dim + 1))
    f = fnn_fractions(x, tau, dims, **kw)
    ok = np.flatnonzero(f < threshold)
    return int(dims[ok[0]]) if len(ok) else max_dim
