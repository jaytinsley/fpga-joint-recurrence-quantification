import json

import numpy as np
import pytest

from jrp import fixedpoint as fp
from jrp.golden import export_case, load_case, pack_flags, unpack_flags
from jrp.jrp import ChannelParams, joint_recurrence_blocked
from jrp.rqa import rqa_metrics
from jrp.signals import gen_coupled_logistic, gen_logistic, gen_uwn


def test_conversion_hand_checked():
    q = fp.to_q824(np.array([0.0, 1.0, -1.0, 0.5, 2.0 ** -24, 0.5 * 2.0 ** -24]))
    assert q.tolist() == [0, 1 << 24, -(1 << 24), 1 << 23, 1, 1]  # ties round toward +inf
    assert fp.to_hex32(q) == ["00000000", "01000000", "FF000000", "00800000", "00000001", "00000001"]


def test_hex_roundtrip_including_negatives():
    q = np.array([0, 1, -1, fp.QMAX, fp.QMIN, 123456789, -987654321], dtype=np.int64)
    assert np.array_equal(fp.from_hex32(fp.to_hex32(q)), q)


def test_saturation_is_logged_and_clipped():
    log = fp.SaturationLog()
    q = fp.to_q824(np.array([200.0, -200.0, 1.0]), log, "sig")
    assert q.tolist() == [fp.QMAX, fp.QMIN, 1 << 24]
    assert len(log) == 2 and log.events[0]["index"] == 0 and log.events[1]["index"] == 1
    with pytest.raises(ValueError):
        fp.to_q824(np.array([np.nan]))


def test_eps2_conversion():
    assert fp.eps2_to_q824(0.5) == 1 << 22  # 0.25 * 2**24
    log = fp.SaturationLog()
    assert fp.eps2_to_q824(100.0, log) == fp.UMAX and len(log) == 1


def test_integer_distance_is_exact_and_threshold_is_inclusive():
    # a = 0, b = 0.5 in one dimension: squared distance 0.25 -> raw 2**46 at scale 2**48.
    A = np.array([[0]], dtype=np.int64)
    B = np.array([[1 << 23]], dtype=np.int64)
    assert fp.sq_dist_block_q824(A, B)[0, 0] == 1 << 46
    eps2 = fp.eps2_to_q824(0.5)  # exactly 0.25 in Q8.24
    assert fp.recurrence_flags_q824(np.vstack([A, B]), eps2)[0, 1] == 1  # <= includes equality
    assert fp.recurrence_flags_q824(np.vstack([A, B]), eps2 - 1)[0, 1] == 0


def test_integer_model_matches_float_model_on_random_data():
    x = gen_uwn(400, seed=9)
    V = np.stack([x[k:len(x) - 4 + k] for k in range(5)], axis=1)
    eps = 0.8
    from jrp.jrp import recurrence_matrix_blocked
    Rf = recurrence_matrix_blocked(V, eps)
    Rq = fp.recurrence_flags_q824(fp.to_q824(V), fp.eps2_to_q824(eps))
    assert (Rf != Rq).sum() <= 3  # only pairs within ~1e-7 of the threshold may flip


def test_pack_unpack_bit_order():
    R = np.zeros((6, 6), dtype=np.uint8)
    R[0, 0] = 1       # pair 0  -> word 0 bit 0
    R[0, 5] = 1       # pair 5  -> bit 5
    R[5, 5] = 1       # pair 35 -> word 1 bit 3
    w = pack_flags(R)
    assert w == ["00000021", "00000008"]
    assert np.array_equal(unpack_flags(w, 6), R)


def test_export_roundtrip_dual_channel(tmp_path):
    x, y = gen_coupled_logistic(120, 0.1)
    px, py = ChannelParams(3, 2, eps_percent=40.0), ChannelParams(2, 1, eps_percent=50.0)
    side = export_case("t", tmp_path, x, y, px, py, source={"gen": "coupled_logistic", "c": 0.1})
    side2, R = load_case("t", tmp_path)
    assert side == json.loads((tmp_path / "t.json").read_text())
    assert R.shape == (side["n_vectors"],) * 2
    # reload the hex input, recompute independently, compare to the stored expectation
    xq = fp.from_hex32((tmp_path / "t_x.hex").read_text().split())
    assert np.array_equal(xq, fp.to_q824(x))
    m = rqa_metrics(R, 2, 2, convention="rtl")
    assert side["expected_metrics"]["JRR"] == pytest.approx(m["RR"])
    assert side["expected_metrics"]["Vmax"] == m["Vmax"]
    # raw counters in the sidecar reproduce the stored metrics through the host formulas
    from jrp.rqa import metrics_from_counters
    for scan, key in (("full", "expected_counters_full_scan"), ("upper", "expected_counters_upper_scan")):
        c = dict(side[key])
        c["det_hist"] = {int(k): v for k, v in c["det_hist"].items()}
        mm = metrics_from_counters(c, side["n_vectors"], scan=scan)
        assert mm["RR"] == pytest.approx(side["expected_metrics"]["JRR"])
        assert mm["LAM"] == pytest.approx(side["expected_metrics"]["JLAM"])
        assert mm["DET"] == pytest.approx(side["expected_metrics"]["JDET"])
    # flags file has one word per pair in grid order
    flat = [int(s, 16) for s in (tmp_path / "t_flags.hex").read_text().split()]
    assert np.array_equal(np.array(flat).reshape(R.shape), R)
    # float model agrees except possibly at a few threshold-borderline pairs
    JR, _ = joint_recurrence_blocked(x, y, px, py)
    assert (JR != R).sum() <= 5
    # vector file: m words per vector, newest first
    vec = fp.from_hex32((tmp_path / "t_vec_x.hex").read_text().split()).reshape(-1, 3)
    n = side["n_vectors"]
    assert np.array_equal(vec[:, 0], fp.to_q824(x)[len(x) - n:])  # component 0 = newest sample


def test_export_single_channel_has_no_y_files(tmp_path):
    side = export_case("s", tmp_path, gen_logistic(100), None, ChannelParams(5, 3, eps_percent=50.0))
    assert side["channels"] == 1 and not (tmp_path / "s_y.hex").exists()
    assert "RR" in side["expected_metrics"]


def test_saturated_inputs_use_exact_arithmetic_and_log_events():
    x = np.array([0.0, 200.0, -200.0, 3.0, 100.0, 127.5, -128.0, 0.5])
    log = fp.SaturationLog()
    q = fp.to_q824(x, log, "x")
    assert len(log) == 2 and q.max() == fp.QMAX and q.min() == fp.QMIN
    V = q.reshape(-1, 1)
    thr_raw = fp.eps2_to_q824(100.0)  # eps = 100, eps^2 = 10000 < 2^8 limit? no: saturates to UMAX
    assert thr_raw == fp.UMAX
    R = fp.recurrence_flags_q824(V, thr_raw)  # exercises the object-dtype fallback
    # brute force with Python integers, including the 32-bit wrap of the difference register
    def wrap(d):
        return ((d + (1 << 31)) % (1 << 32)) - (1 << 31)
    want = np.array([[1 if wrap(int(a) - int(b)) ** 2 <= (fp.UMAX << fp.FRAC) else 0 for b in q] for a in q],
                    dtype=np.uint8)
    assert np.array_equal(R, want)
    with pytest.raises(ValueError):
        fp.recurrence_flags_q824(np.full((600, 1), fp.QMAX, dtype=np.int64), 1)
