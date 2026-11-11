"""Task 4 expectations as tests, at reduced size (N = 1024) so they run quickly."""
import numpy as np
import pytest

from jrp.jrp import ChannelParams, embed_pair, recurrence_matrix_blocked, resolve_eps
from jrp.pipeline import jrp_rqa, rp_rqa
from jrp.signals import (gen_coupled_logistic, gen_harmonic_5_osc, gen_logistic,
                         gen_lorenz_x_resampled, gen_uwn)

P = ChannelParams(5, 3, eps_percent=50.0)


@pytest.mark.parametrize("x", [gen_uwn(700, seed=1), gen_logistic(700), gen_lorenz_x_resampled(700),
                               gen_harmonic_5_osc(700)], ids=["uwn", "logistic", "lorenz", "harmonic"])
def test_identical_systems_give_the_single_rp(x):
    mj, JR = jrp_rqa(x, x, P, P, convention="paper")
    ms, R = rp_rqa(x, 5, 3, 50.0, include_main_diag=False)
    assert np.array_equal(JR, R)
    assert (mj["JRR"], mj["JDET"], mj["JLAM"], mj["Lmax"], mj["Vmax"], mj["ENTR"]) == \
        (ms["RR"], ms["DET"], ms["LAM"], ms["Lmax"], ms["Vmax"], ms["ENTR"])


@pytest.mark.parametrize("pct", [40, 50, 60])
def test_independent_noise_jrr_is_product_of_rr(pct):
    p = ChannelParams(5, 3, eps_percent=float(pct))
    ratios = []
    for s in range(4):
        x, y = gen_uwn(1200, seed=10 + s), gen_uwn(1200, seed=50 + s)
        m, _ = jrp_rqa(x, y, p, p)
        Vx, Vy = embed_pair(x, y, p, p)
        rx = recurrence_matrix_blocked(Vx, resolve_eps(Vx, p)).mean()
        ry = recurrence_matrix_blocked(Vy, resolve_eps(Vy, p)).mean()
        ratios.append(m["JRR"] / (rx * ry))
    assert np.mean(ratios) == pytest.approx(1.0, abs=0.03)


def mean_metrics(c, n_real=6, n=1024):
    rng = np.random.default_rng(7)
    acc = []
    for _ in range(n_real):
        x0, y0 = rng.uniform(0.1, 0.9, 2)
        x, y = gen_coupled_logistic(n, c, r=3.9, x0=x0, y0=y0, mode="drive")
        m, _ = jrp_rqa(x, y, P, P)
        acc.append([m["JRR"], m["JDET"], m["JLAM"]])
    return np.mean(acc, axis=0)


def test_jrr_jdet_jlam_increase_with_coupling_chaotic_drive_response():
    """r = 3.9 (fully chaotic), unidirectional coupling: the clean expected outcome."""
    lo, mid, hi = mean_metrics(0.0), mean_metrics(0.1), mean_metrics(0.3)
    assert np.all(mid > lo) and np.all(hi > mid)


def test_coupling_zero_matches_independent_dynamics_and_generator_modes():
    x, y = gen_coupled_logistic(300, 0.0, x0=0.3, y0=0.7)
    from jrp.signals import to_unit_interval
    assert np.allclose(x, to_unit_interval(gen_logistic(300, x0=0.3)))
    assert np.allclose(y, to_unit_interval(gen_logistic(300, x0=0.7)))
    xs, ys = gen_coupled_logistic(300, 0.5, mode="mutual")
    xd, yd = gen_coupled_logistic(300, 0.5, mode="drive")
    assert not np.allclose(xs, xd)
    assert np.allclose(xd, to_unit_interval(gen_logistic(300, x0=0.3)))  # drive: x is autonomous
    with pytest.raises(ValueError):
        gen_coupled_logistic(10, 0.1, mode="bad")


def test_strong_mutual_coupling_synchronises():
    x, y = gen_coupled_logistic(1000, 0.3, r=3.9)
    assert np.abs(x - y).max() < 1e-6
