import numpy as np
import pytest

from jrp.jrp import ChannelParams, joint_recurrence_blocked
from jrp.rqa import metrics_from_counters, rqa_metrics, rtl_counters
from jrp.signals import gen_coupled_logistic, gen_logistic, gen_lorenz_x_resampled, gen_uwn


def test_all_ones_hand_checked_both_scans():
    R = np.ones((5, 5), dtype=np.uint8)
    full = rtl_counters(R, scan="full")
    # strict upper diagonals have lengths 4, 3, 2, 1 -> the length-1 line is below lmin
    assert (full["rr_count"], full["det_points"], full["det_lines"], full["l_max"]) == (20, 9, 3, 4)
    assert full["det_hist"] == {4: 1, 3: 1, 2: 1}
    # columns split at the diagonal cell: points 4+3+4+3+4, lines 1+1+2+1+1
    assert (full["lam_points"], full["lam_lines"], full["v_max"]) == (18, 6, 4)
    up = rtl_counters(R, scan="upper")
    assert up["rr_count"] == 10
    for k in ("det_points", "det_lines", "l_max", "lam_points", "lam_lines", "v_max", "det_hist", "lam_hist"):
        assert up[k] == full[k], k


def symmetric_cases():
    p = ChannelParams(5, 3, eps_percent=50.0)
    x, y = gen_coupled_logistic(400, 0.1)
    yield joint_recurrence_blocked(x, y, p, p)[0]
    yield joint_recurrence_blocked(x, y, ChannelParams(3, 2, eps_percent=30.0), ChannelParams(2, 1, eps_percent=60.0))[0]
    for s in (gen_uwn(400, seed=1), gen_logistic(400), gen_lorenz_x_resampled(400)):
        for pct in (20.0, 50.0, 80.0):
            q = ChannelParams(5, 3, eps_percent=pct)
            yield joint_recurrence_blocked(s, s, q, q)[0]


def test_upper_scan_is_exactly_equivalent_to_full_scan():
    for R in symmetric_cases():
        full, up = rtl_counters(R, scan="full"), rtl_counters(R, scan="upper")
        assert up["rr_count"] * 2 == full["rr_count"]
        for k in ("det_points", "det_lines", "l_max", "lam_points", "lam_lines", "v_max", "det_hist", "lam_hist"):
            assert up[k] == full[k], k


@pytest.mark.parametrize("scan", ["full", "upper"])
def test_host_formulas_reproduce_rtl_convention_metrics(scan):
    for R in symmetric_cases():
        want = rqa_metrics(R, 2, 2, convention="rtl")
        got = metrics_from_counters(rtl_counters(R, scan=scan), len(R), scan=scan)
        for k in ("RR", "DET", "LAM", "ENTR"):
            assert got[k] == pytest.approx(want[k], abs=1e-12), k
        assert got["Lmax"] == want["Lmax"] and got["Vmax"] == want["Vmax"]


def test_histograms_are_consistent_with_line_counts():
    R = next(symmetric_cases())
    c = rtl_counters(R)
    assert sum(c["det_hist"].values()) == c["det_lines"]
    assert sum(k * v for k, v in c["det_hist"].items()) == c["det_points"]
    assert sum(c["lam_hist"].values()) == c["lam_lines"]


def test_histogram_bin_clips_at_hist_k_minus_one():
    R = np.ones((12, 12), dtype=np.uint8)
    c = rtl_counters(R, hist_k=5)
    assert max(c["det_hist"]) == 4 and c["det_hist"][4] >= 1  # lengths >= 4 land in bin 4


def test_bad_scan_name():
    with pytest.raises(ValueError):
        rtl_counters(np.ones((3, 3), dtype=np.uint8), scan="lower")
