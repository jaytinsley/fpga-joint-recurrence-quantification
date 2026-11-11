import numpy as np
import pandas as pd
import pytest

from jrp.distance import max_pairwise_distance_blocked
from jrp.embedding import takens_embedding
from jrp.jrp import recurrence_matrix_blocked
from jrp.pipeline import rp_rqa
from jrp.rqa import rqa_metrics_from_R, runs_of_ones
from jrp.signals import gen_harmonic_5_osc, gen_logistic, gen_uwn, to_unit_interval

REF_CSV = "data/reference/logistic_multi_x0_python.csv"


def test_takens_hand_checked():
    V = takens_embedding(np.arange(7.0), m=3, tau=2)
    assert V.shape == (3, 3)
    assert V.tolist() == [[0, 2, 4], [1, 3, 5], [2, 4, 6]]


def test_takens_too_short():
    with pytest.raises(ValueError):
        takens_embedding(np.arange(4.0), m=3, tau=2)


def test_runs_of_ones():
    assert runs_of_ones(np.array([1, 1, 0, 1, 0, 1, 1, 1])) == [2, 1, 3]
    assert runs_of_ones(np.array([], dtype=int)) == []


def test_max_distance_small():
    V = np.array([[0.0, 0.0], [3.0, 4.0], [1.0, 1.0]])
    assert max_pairwise_distance_blocked(V, block=2) == pytest.approx(5.0)


def test_recurrence_matches_bruteforce_across_blocks():
    V = takens_embedding(gen_uwn(200, seed=1), 3, 2)
    eps = 0.4
    brute = (np.linalg.norm(V[:, None] - V[None], axis=2) ** 2 <= eps * eps).astype(np.uint8)
    assert np.array_equal(recurrence_matrix_blocked(V, eps, block=64), brute)


def test_rqa_hand_checked():
    # 4x4 matrix: diagonal of ones plus one off-diagonal pair (0,1),(1,2) forming a length-2 line.
    R = np.eye(4, dtype=np.uint8)
    R[0, 1] = R[1, 2] = 1
    m = rqa_metrics_from_R(R, lmin=2, vmin=2, include_main_diag=True)
    assert m["RR"] == pytest.approx(6 / 16)
    assert m["Lmax"] == 4
    assert m["DET"] == pytest.approx((4 + 2) / 6)
    m2 = rqa_metrics_from_R(R, lmin=2, vmin=2, include_main_diag=False)
    assert m2["Lmax"] == 2
    assert m2["DET"] == pytest.approx(2 / 6)
    assert m2["RR"] == pytest.approx(6 / 16)  # reference keeps the main diagonal in RR


def test_all_recurrent():
    m = rqa_metrics_from_R(np.ones((5, 5), dtype=np.uint8), include_main_diag=True)
    # The two length-1 corner diagonals fall below lmin=2: DET = (25 - 2) / 25.
    assert m["RR"] == 1.0 and m["DET"] == pytest.approx(23 / 25) and m["LAM"] == 1.0
    assert m["Lmax"] == 5 and m["Vmax"] == 5


def test_unit_interval():
    x = to_unit_interval(np.array([2.0, 4.0, 6.0]))
    assert x.tolist() == [0.0, 0.5, 1.0]


def test_cupy_matches_numpy():
    cp = pytest.importorskip("cupy")
    try:
        cp.cuda.runtime.getDeviceCount()
    except Exception:
        pytest.skip("no GPU")
    x = gen_harmonic_5_osc(600)
    a, Ra = rp_rqa(x, 3, 2, 30.0, backend="numpy")
    b, Rb = rp_rqa(x, 3, 2, 30.0, backend="cupy")
    assert np.array_equal(Ra, Rb)
    assert a == b


def test_regression_against_li_et_al_30_realisations():
    """Reproduce the 30 logistic-map results shipped with the Li et al. repo (1e-6)."""
    # round_trip is required: the logistic map is chaotic, so a 1-ulp error in x0
    # from pandas' fast float parser changes the whole trajectory.
    ref = pd.read_csv(REF_CSV, float_precision="round_trip")
    assert len(ref) == 30
    for _, row in ref.iterrows():
        x = gen_logistic(int(row.N), r=row.r, x0=row.x0, burn_in=100)
        got, _ = rp_rqa(x, int(row.m), int(row.tau), row.eps_percent, lmin=2, vmin=2,
                        include_main_diag=False)
        assert got["eps"] == pytest.approx(row.eps, abs=1e-6)
        for k in ("RR", "DET", "LAM", "ENTR"):
            assert got[k] == pytest.approx(row[k], abs=1e-6), (row.x0, k)
        for k in ("Lmax", "Vmax"):
            assert got[k] == int(row[k]), (row.x0, k)
