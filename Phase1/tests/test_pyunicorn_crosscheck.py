"""Cross-check against pyunicorn.timeseries.JointRecurrencePlot (independent implementation).

Findings that shape these tests (established empirically with pyunicorn 1.0.0):
- Euclidean metric with absolute per-channel thresholds gives the same JRP as ours.
- With different (m, tau) per channel, pyunicorn pairs embedded vectors by their FIRST sample
  (our align="start"). The RTL pairs by newest sample (our default align="end").
- RR, LAM, Vmax, Lmax and ENTR equal our "paper" convention exactly.
- pyunicorn's DET divides by the recurrence points off the main diagonal, so
  DET_pyunicorn = DET_paper * rr_num / (rr_num - n).
"""
import numpy as np
import pytest

pyu = pytest.importorskip("pyunicorn.timeseries")

from jrp.jrp import ChannelParams, joint_recurrence_blocked  # noqa: E402
from jrp.rqa import rqa_metrics  # noqa: E402
from jrp.signals import gen_logistic, gen_lorenz_x_resampled, gen_uwn  # noqa: E402

CASES = {
    "same params, low recurrence": (gen_logistic(300, x0=0.37), gen_uwn(300, seed=11), (5, 3, 5, 3), (0.45, 0.45)),
    "different m, tau": (gen_logistic(300, x0=0.37), gen_uwn(300, seed=11), (3, 2, 4, 1), (0.35, 0.30)),
    "high recurrence": (gen_lorenz_x_resampled(400), gen_uwn(400, seed=3), (3, 2, 3, 2), (0.5, 1.0)),
    "m=1": (gen_uwn(250, seed=5), gen_uwn(250, seed=6), (1, 1, 1, 1), (0.3, 0.4)),
}


def pyunicorn_jrp(x, y, dims, eps):
    m1, t1, m2, t2 = dims
    return pyu.JointRecurrencePlot(x, y, dim=(m1, m2), tau=(t1, t2), metric=("euclidean", "euclidean"),
                                   threshold=eps, silence_level=3)


@pytest.mark.parametrize("name", list(CASES))
def test_matrix_and_metrics_match_pyunicorn(name):
    x, y, (m1, t1, m2, t2), (e1, e2) = CASES[name]
    jr = pyunicorn_jrp(x, y, (m1, t1, m2, t2), (e1, e2))
    Rp = np.array(jr.recurrence_matrix()).astype(np.uint8)
    JR, _ = joint_recurrence_blocked(x, y, ChannelParams(m1, t1, eps=e1), ChannelParams(m2, t2, eps=e2),
                                     align="start")
    assert np.array_equal(Rp, JR)

    ours = rqa_metrics(JR, 2, 2, convention="paper")
    n, rr_num = len(JR), int(JR.sum())
    assert ours["RR"] == pytest.approx(jr.recurrence_rate(), abs=1e-12)
    assert ours["LAM"] == pytest.approx(jr.laminarity(v_min=2), abs=1e-12)
    # Same definition (natural log); pyunicorn's summation order differs at the 1e-12 level.
    assert ours["ENTR"] == pytest.approx(jr.diag_entropy(l_min=2), abs=1e-9)
    assert ours["Lmax"] == jr.max_diaglength()
    if ours["Vmax"] >= 2:  # pyunicorn reports 1 for isolated points; we apply v_min = 2
        assert ours["Vmax"] == jr.max_vertlength()
    assert ours["DET"] * rr_num / (rr_num - n) == pytest.approx(jr.determinism(l_min=2), abs=1e-9)
    # and the rtl convention reproduces pyunicorn's DET directly
    assert rqa_metrics(JR, 2, 2, convention="rtl")["DET"] == pytest.approx(jr.determinism(l_min=2), abs=1e-9)


def test_rtl_alignment_differs_from_pyunicorn_for_unequal_embeddings():
    x, y, dims, eps = CASES["different m, tau"]
    Rp = np.array(pyunicorn_jrp(x, y, dims, eps).recurrence_matrix()).astype(np.uint8)
    m1, t1, m2, t2 = dims
    end, _ = joint_recurrence_blocked(x, y, ChannelParams(m1, t1, eps=eps[0]), ChannelParams(m2, t2, eps=eps[1]))
    assert end.shape == Rp.shape and not np.array_equal(end, Rp)
