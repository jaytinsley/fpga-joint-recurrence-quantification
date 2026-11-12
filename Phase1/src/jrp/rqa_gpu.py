"""GPU (CuPy) recurrence matrix and RQA extraction, so that the whole pipeline stays on the device.

The reference pipeline (bench.py) copies the n x n matrix back to the host and extracts the metrics in Python, which takes about
444 ms of the 475 ms CuPy total at N=4096. Here the matrix stays on the device, run lengths come from vectorised difference and
index operations, and only a handful of scalars are copied back. Results are checked against rqa_metrics(R, convention="rtl")
in tests/test_rqa_gpu.py.

Definitions (identical to rqa.rqa_metrics, convention "rtl"): the diagonal cells are non-recurrent; rr_num = recurrence count;
RR = rr_num / N^2; DET and LAM divide by rr_num; diagonal lines are taken from the strict upper triangle and doubled (R is symmetric),
which leaves DET, Lmax and the length distribution (ENTR) equal to the both-triangle values.
"""
from typing import Dict

import numpy as np

from .distance import sq_dist_block


def recurrence_matrix_gpu(V, eps: float, block: int = 1024):
    """n x n uint8 recurrence matrix, left on the device."""
    import cupy as cp
    n = V.shape[0]
    R = cp.empty((n, n), dtype=cp.uint8)
    eps2 = eps * eps
    for i0 in range(0, n, block):
        i1 = min(i0 + block, n)
        for j0 in range(0, n, block):
            j1 = min(j0 + block, n)
            R[i0:i1, j0:j1] = (sq_dist_block(V[i0:i1], V[j0:j1], cp) <= eps2)
    return R


def joint_recurrence_gpu(Vx, Vy, eps_x: float, eps_y: float, block: int = 1024):
    """Joint recurrence matrix (AND of the two channels), left on the device."""
    import cupy as cp
    n = Vx.shape[0]
    ex2, ey2 = eps_x * eps_x, eps_y * eps_y
    JR = cp.empty((n, n), dtype=cp.uint8)
    for i0 in range(0, n, block):
        i1 = min(i0 + block, n)
        for j0 in range(0, n, block):
            j1 = min(j0 + block, n)
            rx = sq_dist_block(Vx[i0:i1], Vx[j0:j1], cp) <= ex2
            ry = sq_dist_block(Vy[i0:i1], Vy[j0:j1], cp) <= ey2
            JR[i0:i1, j0:j1] = (rx & ry)
    return JR


def _run_lengths_rows(M):
    """Lengths of all runs of ones along the rows of a 2-D 0/1 int8 array (runs never cross rows)."""
    import cupy as cp
    r, c = M.shape
    P = cp.zeros((r, c + 2), dtype=cp.int8)
    P[:, 1:-1] = M
    dv = cp.diff(P.ravel())
    starts = cp.flatnonzero(dv == 1)
    ends = cp.flatnonzero(dv == -1)
    return (ends - starts).astype(cp.int32)


def rqa_metrics_gpu(R, lmin: int = 2, vmin: int = 2) -> Dict[str, float]:
    """RR, DET, LAM, Lmax, Vmax, ENTR from a symmetric device recurrence matrix (convention "rtl")."""
    import cupy as cp
    N = R.shape[0]
    R0 = (R != 0).astype(cp.int8)
    idx = cp.arange(N)
    R0[idx, idx] = 0
    rr_num = int(R0.sum())
    if rr_num == 0:
        return dict(RR=0.0, DET=0.0, LAM=0.0, Lmax=0, Vmax=0, ENTR=0.0)

    # vertical lines: R is symmetric, so the runs along rows equal the runs along columns
    v = _run_lengths_rows(R0)
    v = v[v >= vmin]
    lam_pts = int(v.sum()) if v.size else 0
    vmax = int(v.max()) if v.size else 0

    # diagonal lines of the strict upper triangle: row k-1 of D holds the diagonal R0[i, i + k]
    k = idx[1:, None]
    i = idx[None, :]
    valid = (i + k) < N
    flat = i * (N + 1) + k
    flat = cp.where(valid, flat, 0)
    D = R0.ravel()[flat] * valid.astype(cp.int8)
    d = _run_lengths_rows(D)
    d = d[d >= lmin]
    if d.size:
        det_pts = 2 * int(d.sum())
        lmax = int(d.max())
        counts = cp.bincount(d)
        counts = counts[counts > 0].astype(cp.float64)
        p = counts / counts.sum()
        entr = float(-(p * cp.log(p)).sum())
    else:
        det_pts, lmax, entr = 0, 0, 0.0
    return dict(RR=rr_num / (N * N), DET=det_pts / rr_num, LAM=lam_pts / rr_num, Lmax=lmax, Vmax=vmax, ENTR=entr)
