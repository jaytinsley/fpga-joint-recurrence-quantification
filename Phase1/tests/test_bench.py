import numpy as np
import pytest

from jrp import bench
from jrp.jrp import ChannelParams
from jrp.pipeline import jrp_rqa
from jrp.signals import gen_coupled_logistic, gen_logistic

P = ChannelParams(3, 2, eps_percent=40.0)


def gpu_available():
    try:
        import cupy as cp
        return cp.cuda.runtime.getDeviceCount() > 0
    except Exception:
        return False


def test_staged_run_matches_pipeline_and_sums_stages():
    x, y = gen_coupled_logistic(400, 0.1)
    ex, ey, t_md = bench.resolve_eps_absolute(x, y, P, P, 128, "numpy")
    assert t_md > 0
    t, m, n = bench.run_once(x, y, P, P, ex, ey, block=128)
    ref, _ = jrp_rqa(x, y, P, P, convention="rtl", block=128)
    assert m["RR"] == pytest.approx(ref["JRR"]) and m["Lmax"] == ref["Lmax"]
    assert t["T_total"] == pytest.approx(sum(t[s] for s in bench.STAGES))
    assert n == ref["n"]


def test_single_channel_path():
    x = gen_logistic(300)
    ex, ey, _ = bench.resolve_eps_absolute(x, None, P, None, 128, "numpy")
    assert ey is None
    t, m, n = bench.run_once(x, None, P, None, ex, None, block=128)
    assert n == 300 - 2 * 2 and 0 < m["RR"] <= 1


def test_benchmark_requires_five_repeats_and_reports_stats():
    x, y = gen_coupled_logistic(200, 0.1)
    ex, ey, _ = bench.resolve_eps_absolute(x, y, P, P, 128, "numpy")
    with pytest.raises(ValueError):
        bench.benchmark(x, y, P, P, ex, ey, repeats=3)
    r = bench.benchmark(x, y, P, P, ex, ey, repeats=5, block=128)
    assert r["repeats"] == 5 and r["T_total_min_ms"] <= r["T_total_mean_ms"]
    assert all(f"{s}_std_ms" in r for s in bench.STAGES)


@pytest.mark.skipif(not gpu_available(), reason="no GPU")
def test_gpu_events_give_same_metrics_and_positive_times():
    x, y = gen_coupled_logistic(400, 0.1)
    ex, ey, _ = bench.resolve_eps_absolute(x, y, P, P, 128, "numpy")
    tc, mc, _ = bench.run_once(x, y, P, P, ex, ey, backend="cupy", block=128)
    tn, mn, _ = bench.run_once(x, y, P, P, ex, ey, backend="numpy", block=128)
    assert mc == mn
    assert tc["T_psr"] > 0 and tc["T_cmp"] > 0
