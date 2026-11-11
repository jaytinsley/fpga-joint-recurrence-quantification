"""Per-stage timing of the RP / JRP pipeline on the NumPy (CPU) and CuPy (GPU) backends.

Stages follow Li et al.: T_sig (normalisation), T_psr (embedding, including the host to
device copy on GPU), T_cmp (blocked distance and threshold, including the device to host
copy of the recurrence matrix), T_rqa (metric extraction, always on the CPU), T_total =
sum. The maximum-distance search that turns eps from a percentage into an absolute value
is timed separately (T_maxdist) and excluded from T_total, as in the paper.

Timing rules: GPU stages use cupy.cuda.Event record + synchronise + get_elapsed_time, never
perf_counter, because CUDA launches are asynchronous. CPU stages use perf_counter. One
warm-up run is discarded, then `repeats` (>= 5) timed runs are summarised. All times in ms.
"""
import time
from contextlib import contextmanager

import numpy as np

from .backend import get_xp
from .distance import max_pairwise_distance_blocked
from .embedding import takens_embedding
from .jrp import (ChannelParams, embed_pair, joint_recurrence_from_embedded, recurrence_matrix_blocked,
                  resolve_eps)
from .rqa import rqa_metrics
from .signals import to_unit_interval

STAGES = ("T_sig", "T_psr", "T_cmp", "T_rqa")


@contextmanager
def stage(times: dict, name: str, backend: str, device: bool):
    """Time a block. device=True and backend cupy: CUDA events; otherwise perf_counter."""
    if backend == "cupy" and device:
        import cupy as cp
        start, end = cp.cuda.Event(), cp.cuda.Event()
        start.record()
        yield
        end.record()
        end.synchronize()
        times[name] = float(cp.cuda.get_elapsed_time(start, end))
    else:
        if backend == "cupy":
            import cupy as cp
            cp.cuda.Stream.null.synchronize()
        t0 = time.perf_counter()
        yield
        times[name] = (time.perf_counter() - t0) * 1000.0


def resolve_eps_absolute(x, y, px, py, block, backend):
    """Absolute eps per channel from percentages, plus T_maxdist in ms (not in T_total)."""
    xp = get_xp(backend)
    times = {}
    x_u = to_unit_interval(x)
    y_u = to_unit_interval(y) if y is not None else None
    with stage(times, "T_maxdist", backend, True):
        if y is None:
            V = takens_embedding(x_u, px.m, px.tau, xp=xp)
            ex, ey = resolve_eps(V, px, block, xp), None
        else:
            Vx, Vy = embed_pair(x_u, y_u, px, py, xp=xp)
            ex, ey = resolve_eps(Vx, px, block, xp), resolve_eps(Vy, py, block, xp)
    return ex, ey, times["T_maxdist"]


def run_once(x, y, px, py, eps_x, eps_y, backend="numpy", block=1024, lmin=2, vmin=2,
             convention="rtl"):
    """One staged run with absolute eps. y=None runs the single-channel RP. Returns
    (times dict in ms, metrics dict)."""
    xp = get_xp(backend)
    t = {}
    with stage(t, "T_sig", backend, False):
        x_u = to_unit_interval(x)
        y_u = to_unit_interval(y) if y is not None else None
    with stage(t, "T_psr", backend, True):
        if y is None:
            Vx = takens_embedding(x_u, px.m, px.tau, xp=xp)
        else:
            Vx, Vy = embed_pair(x_u, y_u, px, py, xp=xp)
    with stage(t, "T_cmp", backend, True):
        if y is None:
            R = recurrence_matrix_blocked(Vx, eps_x, block=block, xp=xp)
        else:
            R = joint_recurrence_from_embedded(Vx, Vy, eps_x, eps_y, block=block, xp=xp)
    with stage(t, "T_rqa", backend, False):
        metrics = rqa_metrics(R, lmin=lmin, vmin=vmin, convention=convention)
    t["T_total"] = sum(t[s] for s in STAGES)
    return t, metrics, R.shape[0]


def benchmark(x, y, px, py, eps_x, eps_y, backend="numpy", repeats=5, **kw):
    """Warm up once, then time `repeats` runs. Returns a dict of mean/std/min per stage
    (ms) plus the metrics and n of the last run."""
    if repeats < 5:
        raise ValueError("repeats must be >= 5")
    run_once(x, y, px, py, eps_x, eps_y, backend=backend, **kw)  # warm-up, discarded
    runs = [run_once(x, y, px, py, eps_x, eps_y, backend=backend, **kw) for _ in range(repeats)]
    out = {"n_vectors": runs[0][2], "repeats": repeats}
    for s in STAGES + ("T_total",):
        v = np.array([r[0][s] for r in runs])
        out[f"{s}_mean_ms"], out[f"{s}_std_ms"], out[f"{s}_min_ms"] = float(v.mean()), float(v.std(ddof=1)), float(v.min())
    out.update(runs[-1][1])
    return out
