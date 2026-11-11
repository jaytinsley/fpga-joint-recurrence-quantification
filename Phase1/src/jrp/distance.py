"""Blocked pairwise squared distances via the Gram identity.

||a - b||^2 = ||a||^2 + ||b||^2 - 2 a.b, evaluated in block x block tiles so an
N x N float matrix is never materialised. Ported from Li, Lai and Oberst (2026),
Zenodo doi:10.5281/zenodo.20406392 (MIT).
"""
import numpy as np


def sq_dist_block(Vi, Vj, xp=np):
    """Squared Euclidean distances between rows of Vi and rows of Vj, clipped at 0."""
    Vi2 = xp.sum(Vi * Vi, axis=1, keepdims=True)
    Vj2 = xp.sum(Vj * Vj, axis=1, keepdims=True).T
    D2 = Vi2 + Vj2 - 2.0 * (Vi @ Vj.T)
    xp.maximum(D2, 0.0, out=D2)
    return D2


def max_pairwise_distance_blocked(V, block: int = 1024, xp=np) -> float:
    n = V.shape[0]
    maxd2 = 0.0
    for i0 in range(0, n, block):
        Vi = V[i0:min(i0 + block, n)]
        for j0 in range(0, n, block):
            Vj = V[j0:min(j0 + block, n)]
            local = float(xp.max(sq_dist_block(Vi, Vj, xp)))
            if local > maxd2:
                maxd2 = local
    return float(np.sqrt(maxd2))
