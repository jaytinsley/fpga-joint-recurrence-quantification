import numpy as np
import pytest

from jrp.embedding import takens_embedding
from jrp.jrp import ChannelParams, joint_recurrence_blocked, recurrence_matrix_blocked
from jrp.pipeline import jrp_rqa
from jrp.rqa import rqa_metrics
from jrp.signals import gen_logistic, gen_uwn


def brute_rp(V, eps):
    D2 = ((V[:, None, :] - V[None, :, :]) ** 2).sum(axis=2)
    return (D2 <= eps * eps).astype(np.uint8)


def test_channel_params_needs_exactly_one_eps():
    with pytest.raises(ValueError):
        ChannelParams(m=2, tau=1)
    with pytest.raises(ValueError):
        ChannelParams(m=2, tau=1, eps=0.1, eps_percent=10)


def test_jrp_hand_checked_m1():
    # m = 1: recurrence is |a_i - a_j| <= eps per channel.
    x = np.array([0.0, 0.1, 0.9, 1.0])
    y = np.array([0.0, 0.5, 0.0, 0.5])
    JR, info = joint_recurrence_blocked(x, y, ChannelParams(1, 1, eps=0.2), ChannelParams(1, 1, eps=0.1))
    # x recurs for {0,1} and {2,3}; y recurs for {0,2} and {1,3}; AND leaves only the diagonal.
    assert np.array_equal(JR, np.eye(4, dtype=np.uint8))
    assert info == {"n": 4, "eps_x": 0.2, "eps_y": 0.1}


def test_jrp_equals_and_of_channel_rps_and_block_invariant():
    x, y = gen_uwn(300, seed=1), gen_logistic(300)
    px, py = ChannelParams(3, 2, eps=0.5), ChannelParams(2, 3, eps=0.4)
    JR, info = joint_recurrence_blocked(x, y, px, py, block=64)
    n = info["n"]
    Vx = takens_embedding(x, 3, 2)[-n:]  # end-aligned: trailing n vectors, as in the RTL
    Vy = takens_embedding(y, 2, 3)[-n:]
    assert np.array_equal(JR, brute_rp(Vx, 0.5) & brute_rp(Vy, 0.4))
    JR2, _ = joint_recurrence_blocked(x, y, px, py, block=1000)
    assert np.array_equal(JR, JR2)
    assert np.array_equal(JR, JR.T)
    assert JR.diagonal().all()


def test_aligned_length_is_shorter_embedding():
    x = y = np.linspace(0, 1, 100)
    _, info = joint_recurrence_blocked(x, y, ChannelParams(5, 3, eps=0.1), ChannelParams(2, 1, eps=0.1))
    assert info["n"] == 100 - 4 * 3


def test_end_alignment_pairs_vectors_by_newest_sample():
    # Vector at time t: x ends at t. Make channel values encode t so we can check pairing.
    t = np.arange(40.0)
    from jrp.jrp import embed_pair
    Vx, Vy = embed_pair(t, t, ChannelParams(4, 3, eps=1), ChannelParams(2, 1, eps=1))
    assert Vx.shape[0] == Vy.shape[0] == 40 - 9
    assert np.array_equal(Vx[:, -1], Vy[:, -1])  # same newest sample in each pair
    assert Vx[0, -1] == 9  # first pair ends on sample (m-1)*tau of the longer channel
    Sx, Sy = embed_pair(t, t, ChannelParams(4, 3, eps=1), ChannelParams(2, 1, eps=1), align="start")
    assert np.array_equal(Sx[:, 0], Sy[:, 0])
    with pytest.raises(ValueError):
        embed_pair(t, t, ChannelParams(4, 3, eps=1), ChannelParams(2, 1, eps=1), align="mid")


def test_identical_channels_give_single_rp():
    x = gen_logistic(500)
    p = ChannelParams(5, 3, eps_percent=50.0)
    JR, info = joint_recurrence_blocked(x, x, p, p, block=128)
    V = takens_embedding(x, 5, 3)
    R = recurrence_matrix_blocked(V, info["eps_x"], block=128)
    assert np.array_equal(JR, R)


def test_unequal_lengths_rejected():
    with pytest.raises(ValueError):
        joint_recurrence_blocked(np.zeros(10), np.zeros(11), ChannelParams(1, 1, eps=1), ChannelParams(1, 1, eps=1))


def test_eps_percent_is_per_channel():
    x = gen_uwn(200, seed=2)
    y = 10.0 * gen_uwn(200, seed=3)  # different scale; the percent rule is scale-free
    _, info = joint_recurrence_blocked(x, y, ChannelParams(2, 1, eps_percent=50), ChannelParams(2, 1, eps_percent=50))
    assert info["eps_y"] > 5 * info["eps_x"]


def test_rtl_convention_all_ones_hand_checked():
    # 5x5 all ones with the diagonal removed (see rqa_metrics docstring).
    # Columns split at the LOI: runs {4}, {1,3}, {2,2}, {3,1}, {4} -> LAM points 4+3+4+3+4 = 18.
    # Diagonals k=+-1..3 have lengths 4,3,2 (k=+-4 has length 1 < lmin): 2*(4+3+2) = 18 points.
    m = rqa_metrics(np.ones((5, 5), dtype=np.uint8), convention="rtl")
    assert m["RR"] == pytest.approx(20 / 25)  # rr_count = 20 off-diagonal cells, over N**2
    assert m["LAM"] == pytest.approx(18 / 20)
    assert m["DET"] == pytest.approx(18 / 20)
    assert m["Vmax"] == 4 and m["Lmax"] == 4


def test_conventions_differ_only_through_the_diagonal():
    R = np.ones((6, 6), dtype=np.uint8)
    a, b = rqa_metrics(R, convention="paper"), rqa_metrics(R, convention="rtl")
    assert a["Vmax"] == 6 and b["Vmax"] == 5
    assert a["RR"] == 1.0 and b["RR"] == pytest.approx(30 / 36)  # diagonal not counted in rtl
    with pytest.raises(ValueError):
        rqa_metrics(R, convention="nope")


def test_rtl_convention_does_not_mutate_input():
    R = np.ones((4, 4), dtype=np.uint8)
    rqa_metrics(R, convention="rtl")
    assert R.diagonal().all()


def test_jrp_rqa_pipeline_and_cupy_parity():
    x, y = gen_logistic(700), gen_uwn(700, seed=5)
    px, py = ChannelParams(3, 2, eps_percent=30), ChannelParams(2, 1, eps_percent=40)
    a, JRa = jrp_rqa(x, y, px, py, convention="rtl")
    assert set(a) >= {"JRR", "JDET", "JLAM", "Lmax", "Vmax", "ENTR", "eps_x", "eps_y", "n"}
    cp = pytest.importorskip("cupy")
    try:
        cp.cuda.runtime.getDeviceCount()
    except Exception:
        pytest.skip("no GPU")
    b, JRb = jrp_rqa(x, y, px, py, convention="rtl", backend="cupy")
    assert np.array_equal(JRa, JRb)
    assert a == b
