"""RQA metric extraction from a recurrence matrix.

Ported from Li, Lai and Oberst (2026), Zenodo doi:10.5281/zenodo.20406392 (MIT).
Behaviour is kept identical to the reference, including how `include_main_diag`
is applied (see the docstring of rqa_metrics_from_R).
"""
from typing import Dict, List

import numpy as np


def runs_of_ones(vec: np.ndarray) -> List[int]:
    if vec.size == 0:
        return []
    v = vec.astype(np.int8)
    dv = np.diff(np.r_[0, v, 0])
    starts = np.flatnonzero(dv == 1)
    ends = np.flatnonzero(dv == -1)
    return (ends - starts).tolist()


def rqa_metrics_from_R(R: np.ndarray, lmin: int = 2, vmin: int = 2,
                       include_main_diag: bool = True) -> Dict[str, float]:
    """RR, DET, LAM, Lmax, Vmax, ENTR from a binary recurrence matrix.

    Reference behaviour: include_main_diag=False only skips the k=0 diagonal when
    collecting diagonal lines (DET, Lmax, ENTR). RR, LAM and the denominators
    still count the main diagonal. The RTL extractor excludes i == j from RR and
    LAM as well, so the two differ by O(1/N).
    """
    Rb = (R.astype(np.uint8) != 0)
    N = Rb.shape[0]

    rr_num = int(Rb.sum())
    rr_den = N * N
    RR = rr_num / rr_den if rr_den else 0.0

    diag_lengths_all = []
    diag_point_sum = 0
    Lmax = 0
    for k in range(-(N - 1), N):
        if not include_main_diag and k == 0:
            continue
        d = np.diag(Rb, k=k)
        lens = runs_of_ones(d)
        sel = [L for L in lens if L >= lmin]
        if sel:
            diag_lengths_all.extend(sel)
            diag_point_sum += sum(sel)
            Lmax = max(Lmax, max(sel))

    DET = (diag_point_sum / rr_num) if rr_num > 0 else 0.0

    if len(diag_lengths_all) > 0:
        vals, counts = np.unique(np.asarray(diag_lengths_all, dtype=np.int32), return_counts=True)
        p = counts.astype(np.float64) / counts.sum()
        ENTR = float(-(p * np.log(p)).sum())
    else:
        ENTR = 0.0

    vert_point_sum = 0
    Vmax = 0
    for j in range(N):
        lens = runs_of_ones(Rb[:, j])
        sel = [L for L in lens if L >= vmin]
        if sel:
            vert_point_sum += sum(sel)
            Vmax = max(Vmax, max(sel))

    LAM = (vert_point_sum / rr_num) if rr_num > 0 else 0.0

    return dict(RR=RR, DET=DET, LAM=LAM, Lmax=int(Lmax), Vmax=int(Vmax), ENTR=ENTR)


CONVENTIONS = ("paper", "rtl")


def rqa_metrics(R: np.ndarray, lmin: int = 2, vmin: int = 2,
                convention: str = "paper") -> Dict[str, float]:
    """RQA metrics under a named counting convention.

    "paper": the Li et al. Python reference (main diagonal counted in RR and LAM).
    "rtl":   what rtl/RQA_extractor_nobitmap.v computes. The LOI cell (i == j) is
             non-recurrent everywhere, so it breaks vertical lines and is not in
             rr_count. The RTL counts diagonal lines on the strict upper triangle
             only; for a symmetric R, 2 * (upper-triangle line points) equals the
             both-triangle count used here, so DET, Lmax and ENTR are unchanged.
             RR = rr_count / N**2, the denominator in Eq. 2 of the Li et al. preprint
             (the RTL itself only reports rr_count; the host chooses the denominator,
             so confirm with the authors). Note rr_count excludes the N diagonal cells,
             so a fully recurrent plot gives RR = (N - 1) / N, not 1.
             DET and LAM divide by rr_count, as the paper's Eqs. 3 and 4 do.
    R must be symmetric (true for any RP or JRP).
    """
    if convention == "paper":
        return rqa_metrics_from_R(R, lmin, vmin, include_main_diag=False)
    if convention == "rtl":
        R0 = np.array(R, dtype=np.uint8, copy=True)
        np.fill_diagonal(R0, 0)
        # rqa_metrics_from_R already divides by N**2; with the diagonal cleared the
        # numerator is exactly the RTL's rr_count.
        return rqa_metrics_from_R(R0, lmin, vmin, include_main_diag=False)
    raise ValueError(f"convention must be one of {CONVENTIONS}, got {convention!r}")


# ---- RTL-visible counters (what rtl/RQA_extractor_nobitmap.v reports) and the host formulas
# ---- that turn them into metrics. Used for Phase 2 and for RTL verification: a testbench
# ---- compares these integers, which do not depend on any host-side convention.

HIST_K = 8192  # histogram bins in the RTL; bin = min(length, HIST_K - 1)


def _runs(vec):
    return runs_of_ones(np.asarray(vec))


def _tally(lengths, minlen, hist_k, hist):
    pts = lines = longest = 0
    for L in lengths:
        if L >= minlen:
            pts += L
            lines += 1
            longest = max(longest, L)
            b = min(L, hist_k - 1)
            hist[b] = hist.get(b, 0) + 1
    return pts, lines, longest


def rtl_counters(R, lmin: int = 2, vmin: int = 2, hist_k: int = HIST_K, scan: str = "full"):
    """Integer counters of the RTL extractor for a symmetric recurrence matrix R.

    scan="full":  the released RTL, which receives all N*N cells in row-major order (i outer,
                  j inner). rr_count is the off-diagonal recurrence count; det_* count the
                  strict upper triangle only; lam_* count every column with the cell (j, j)
                  treated as non-recurrent.
    scan="upper": a half-length scan that streams only cells with i < j. rr_count is then the
                  upper-triangle count; DET is the same; LAM is rebuilt from column runs in
                  the upper triangle plus row runs in the upper triangle. For a symmetric R
                  these give exactly the same lam_* counters and histograms as the full scan
                  (a column run below the diagonal mirrors a row run to the right of it, and
                  no run crosses the diagonal because that cell is non-recurrent).
    Returns a dict with rr_count, det_points, det_lines, l_max, lam_points, lam_lines, v_max
    and the sparse histograms det_hist, lam_hist ({bin: count}).
    """
    n = R.shape[0]
    R0 = np.array(R, dtype=np.uint8, copy=True)
    np.fill_diagonal(R0, 0)
    det_hist, lam_hist = {}, {}
    det_pts = det_lines = lmax = 0
    for k in range(1, n):
        p, c, m = _tally(_runs(np.diag(R0, k)), lmin, hist_k, det_hist)
        det_pts, det_lines, lmax = det_pts + p, det_lines + c, max(lmax, m)
    lam_pts = lam_lines = vmax = 0

    def add(lengths):
        nonlocal lam_pts, lam_lines, vmax
        p, c, m = _tally(lengths, vmin, hist_k, lam_hist)
        lam_pts, lam_lines, vmax = lam_pts + p, lam_lines + c, max(vmax, m)

    if scan == "full":
        rr = int(R0.sum())
        for j in range(n):
            add(_runs(R0[:, j]))
    elif scan == "upper":
        rr = int(np.triu(R0, 1).sum())
        for j in range(n):
            add(_runs(R0[:j, j]))          # column j, rows above the diagonal
        for i in range(n):
            add(_runs(R0[i, i + 1:]))      # row i, columns right of the diagonal
    else:
        raise ValueError("scan must be 'full' or 'upper'")
    return dict(rr_count=rr, det_points=det_pts, det_lines=det_lines, l_max=lmax,
                lam_points=lam_pts, lam_lines=lam_lines, v_max=vmax,
                det_hist=det_hist, lam_hist=lam_hist)


def metrics_from_counters(c: dict, n: int, scan: str = "full") -> Dict[str, float]:
    """Host-side formulas: RTL counters -> RR, DET, LAM, Lmax, Vmax, ENTR ("rtl" convention).

    n is the number of embedded vectors N. The strict upper triangle holds half of the
    off-diagonal cells, so det_points is doubled (a symmetric R has equal lines in both
    triangles); with scan="upper" rr_count is the upper-triangle count and is doubled too.
    RR = rr_count / N**2, DET = 2 det_points / rr_count, LAM = lam_points / rr_count.
    ENTR = -sum p ln p with p the DET histogram bin frequencies (natural log, not normalised).
    """
    rr = c["rr_count"] * (2 if scan == "upper" else 1)
    h = c["det_hist"]
    total = sum(h.values())
    entr = -sum((v / total) * np.log(v / total) for v in h.values()) if total else 0.0
    return dict(RR=rr / n**2,
                DET=2 * c["det_points"] / rr if rr else 0.0,
                LAM=c["lam_points"] / rr if rr else 0.0,
                Lmax=int(c["l_max"]), Vmax=int(c["v_max"]), ENTR=float(entr))
