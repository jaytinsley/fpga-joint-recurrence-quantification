"""Single-channel RP + RQA pipeline: eps as a percentage of max embedded distance."""
import numpy as np

from .backend import get_xp
from .distance import max_pairwise_distance_blocked
from .embedding import takens_embedding
from .jrp import recurrence_matrix_blocked
from .rqa import rqa_metrics_from_R
from .signals import to_unit_interval


def eps_from_percent(V, percent: float, block: int = 1024, xp=np) -> float:
    maxd = max_pairwise_distance_blocked(V, block=block, xp=xp)
    if not np.isfinite(maxd) or maxd <= 0:
        raise ValueError(f"invalid max distance {maxd}")
    return max((percent / 100.0) * maxd, np.finfo(np.float64).tiny)


def rp_rqa(x, m: int, tau: int, eps_percent: float, lmin: int = 2, vmin: int = 2,
           include_main_diag: bool = False, block: int = 1024, backend: str = "numpy"):
    """Run the single-channel pipeline. Returns (metrics dict incl. N and eps, R)."""
    xp = get_xp(backend)
    x_u = to_unit_interval(np.asarray(x, dtype=np.float64))
    V = takens_embedding(x_u, m, tau, xp=xp)
    eps = eps_from_percent(V, eps_percent, block=block, xp=xp)
    R = recurrence_matrix_blocked(V, eps, block=block, xp=xp)
    metrics = rqa_metrics_from_R(R, lmin=lmin, vmin=vmin, include_main_diag=include_main_diag)
    return {"N": len(x_u), "eps": eps} | metrics, R


def jrp_rqa(x, y, px, py, lmin: int = 2, vmin: int = 2, convention: str = "paper",
            block: int = 1024, backend: str = "numpy", normalise: bool = True,
            align: str = "end"):
    """Dual-channel pipeline. Returns (dict of JRQA metrics and parameters, JR).

    Each channel is normalised to [0, 1] separately when normalise is True.
    Metric names: JRR, JDET, JLAM, Lmax, Vmax, ENTR.
    """
    from .jrp import joint_recurrence_blocked
    from .rqa import rqa_metrics

    xp = get_xp(backend)
    x = np.asarray(x, dtype=np.float64)
    y = np.asarray(y, dtype=np.float64)
    if normalise:
        x, y = to_unit_interval(x), to_unit_interval(y)
    JR, info = joint_recurrence_blocked(x, y, px, py, block=block, xp=xp, align=align)
    m = rqa_metrics(JR, lmin=lmin, vmin=vmin, convention=convention)
    out = {"N": len(x), **info, "JRR": m["RR"], "JDET": m["DET"], "JLAM": m["LAM"],
           "Lmax": m["Lmax"], "Vmax": m["Vmax"], "ENTR": m["ENTR"]}
    return out, JR
