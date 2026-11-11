"""Independent re-implementation of the JRP and RQA metrics (task 5 stand-in).

Different code paths from src/jrp: scipy cdist for distances, a window-based embedding,
and plain-Python scanning for line lengths, no numpy diagonals or run-length helpers.
Definitions are the same (Marwan et al. 2007; Romano et al. 2004). pyunicorn could not be
installed (no Windows wheel, no C compiler), so the pyunicorn comparison is still open.
"""
import math

import numpy as np
import pytest
from scipy.spatial.distance import cdist

from jrp.jrp import ChannelParams
from jrp.pipeline import jrp_rqa
from jrp.signals import gen_logistic, gen_uwn, to_unit_interval


def embed(x, m, tau):
    n = len(x) - (m - 1) * tau
    return np.array([[x[i + k * tau] for k in range(m)] for i in range(n)])


def jr_matrix(x, y, mx, tx, my, ty, ex, ey):
    Vx, Vy = embed(x, mx, tx), embed(y, my, ty)
    n = min(len(Vx), len(Vy))
    Vx, Vy = Vx[len(Vx) - n:], Vy[len(Vy) - n:]  # end-aligned, as the RTL pairs vectors
    Rx = cdist(Vx, Vx) <= ex
    Ry = cdist(Vy, Vy) <= ey
    return (Rx & Ry).astype(int), Vx, Vy


def runs(seq):
    out, cur = [], 0
    for v in seq:
        if v:
            cur += 1
        elif cur:
            out.append(cur)
            cur = 0
    if cur:
        out.append(cur)
    return out


def metrics_naive(R, lmin=2, vmin=2):
    n = len(R)
    rr_num = sum(sum(row) for row in R)
    diag_lens = []
    for k in range(-(n - 1), n):
        if k == 0:
            continue
        seq = [R[i][i + k] for i in range(max(0, -k), min(n, n - k))]
        diag_lens += [L for L in runs(seq) if L >= lmin]
    vert_lens = []
    for j in range(n):
        vert_lens += [L for L in runs([R[i][j] for i in range(n)]) if L >= vmin]
    entr = 0.0
    if diag_lens:
        total = len(diag_lens)
        for L in set(diag_lens):
            p = diag_lens.count(L) / total
            entr -= p * math.log(p)
    return dict(RR=rr_num / n**2,
                DET=sum(diag_lens) / rr_num if rr_num else 0.0,
                LAM=sum(vert_lens) / rr_num if rr_num else 0.0,
                Lmax=max(diag_lens, default=0), Vmax=max(vert_lens, default=0), ENTR=entr)


CASES = [
    ("same params", 5, 3, 5, 3, 0.45, 0.45),
    ("different m, tau", 3, 2, 4, 1, 0.35, 0.30),
    ("m=1", 1, 1, 1, 1, 0.20, 0.25),
]


@pytest.mark.parametrize("name,mx,tx,my,ty,ex,ey", CASES)
def test_jrp_and_metrics_match_independent_implementation(name, mx, tx, my, ty, ex, ey):
    x = to_unit_interval(gen_logistic(260, x0=0.37))
    y = to_unit_interval(gen_uwn(260, seed=11))
    R_ref, _, _ = jr_matrix(x, y, mx, tx, my, ty, ex, ey)
    ref = metrics_naive(R_ref.tolist())
    got, JR = jrp_rqa(x, y, ChannelParams(mx, tx, eps=ex), ChannelParams(my, ty, eps=ey),
                      convention="paper", normalise=False, block=100)
    assert np.array_equal(JR, R_ref)
    assert got["JRR"] == pytest.approx(ref["RR"], abs=1e-12)
    assert got["JDET"] == pytest.approx(ref["DET"], abs=1e-12)
    assert got["JLAM"] == pytest.approx(ref["LAM"], abs=1e-12)
    assert got["ENTR"] == pytest.approx(ref["ENTR"], abs=1e-12)
    assert got["Lmax"] == ref["Lmax"] and got["Vmax"] == ref["Vmax"]


def test_eps_percent_matches_independent_max_distance():
    x, y = gen_uwn(200, seed=3), gen_logistic(200)
    _, JR = jrp_rqa(x, y, ChannelParams(3, 2, eps_percent=40), ChannelParams(2, 1, eps_percent=60),
                    normalise=False)
    n = len(JR)
    Vx, Vy = embed(x, 3, 2)[-n:], embed(y, 2, 1)[-n:]
    ex, ey = 0.4 * cdist(Vx, Vx).max(), 0.6 * cdist(Vy, Vy).max()
    assert np.array_equal(JR, ((cdist(Vx, Vx) <= ex) & (cdist(Vy, Vy) <= ey)).astype(np.uint8))
