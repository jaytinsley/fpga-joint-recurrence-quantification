"""GHKSS nonlinear noise reduction, Python reference (float64, CPU).

Algorithm: Grassberger, Hegger, Kantz, Schaffrath and Schreiber (1993), "On noise
reduction methods for chaotic data", Chaos 3, 127; as implemented in TISEAN `ghkss`
(Hegger, Kantz, Schreiber 1999). This is the reference for the ARM PS in Phase 4.

For every delay vector z_n in R^m:
  1. take its neighbourhood U_n (all vectors within eps, or the k_min nearest if fewer);
  2. compute the neighbourhood centroid c_n and covariance matrix C_n;
  3. the q eigenvectors of C_n with the largest eigenvalues span the local tangent space
     of the attractor (manifold dimension q); the other m - q span the noise directions;
  4. the correction is d_n = -P_n (z_n - c_n), P_n the orthogonal projector onto the
     noise directions.
Each sample x_t appears in up to m delay vectors, so its final correction is the mean of
the corresponding components of d_n. The whole pass can be repeated (iterations).

Differences from TISEAN that have NOT been checked against its binary (not installed):
equal weights in the neighbourhood covariance (no Gaussian weighting), a plain
Euclidean projector with no weighting of the first and last delay coordinates, and
Euclidean (not max-norm) neighbourhoods.
"""
import numpy as np
from scipy.spatial import cKDTree


def delay_vectors(x: np.ndarray, m: int, tau: int) -> np.ndarray:
    n = len(x) - (m - 1) * tau
    if n <= 0:
        raise ValueError("series too short for m, tau")
    return np.stack([x[k * tau: k * tau + n] for k in range(m)], axis=1)


def _one_pass(x: np.ndarray, m: int, tau: int, q: int, k_min: int, eps: float):
    Z = delay_vectors(x, m, tau)
    n = len(Z)
    tree = cKDTree(Z)
    corr = np.zeros_like(x)
    cnt = np.zeros_like(x)
    idx_base = np.arange(n)
    for i in range(n):
        nb = tree.query_ball_point(Z[i], eps)
        if len(nb) < k_min:
            _, nb = tree.query(Z[i], k=min(k_min, n))
        U = Z[nb]
        c = U.mean(axis=0)
        C = (U - c).T @ (U - c) / len(U)
        w, V = np.linalg.eigh(C)              # ascending eigenvalues
        noise = V[:, : m - q]                 # smallest m - q: noise directions
        d = -noise @ (noise.T @ (Z[i] - c))   # orthogonal projection onto noise space
        for j in range(m):
            t = i + j * tau
            corr[t] += d[j]
            cnt[t] += 1
    return x + corr / np.maximum(cnt, 1)


def ghkss(x, m: int, tau: int = 1, q: int = 2, k_min: int = 30, eps: float = None,
          iterations: int = 1):
    """Return the noise-reduced series (same length as x).

    m: embedding dimension; tau: delay (samples); q: manifold dimension (1 <= q < m);
    k_min: minimum neighbours; eps: neighbourhood radius in signal units (default: 0.1 of the
    std of x times sqrt(m)); iterations: number of passes. Deterministic.
    """
    x = np.asarray(x, dtype=np.float64).copy()
    if not 1 <= q < m:
        raise ValueError("need 1 <= q < m")
    if eps is None:
        eps = 0.1 * float(np.std(x)) * np.sqrt(m)
    for _ in range(iterations):
        x = _one_pass(x, m, tau, q, k_min, eps)
    return x


def ghkss_pkg(x, dim: int, q: int, iterations: int = 8, k_min: int = 30, batch_size=None, euclidean_norm: bool = False):
    """GHKSS via the PyPI `ghkss` package (C++, corrected TISEAN drop-in; Kantz group, v1.0.3).

    x is one series (a column vector for the package). Delay vector pattern is 0..dim-1 (delay 1).
    Needs 1 <= q < dim: with q >= dim the package leaves the series unchanged. Defaults follow TISEAN
    (30 neighbours, max norm). batch_size splits the series into independently filtered blocks.
    """
    import ghkss as G
    if not 1 <= q < dim:
        raise ValueError("need 1 <= q < dim")
    kw = dict(iterations=iterations, delay_vector_pattern=list(range(dim)), projection_dimension=q,
              minimum_neighbour_count=k_min, euclidean_norm=euclidean_norm)
    if batch_size is not None:
        kw["batch_size"] = batch_size
    y = G.filter_ghkss(np.asarray(x, dtype=np.float64).reshape(-1, 1), G.FilterConfig(**kw))
    return np.asarray(y).ravel()
