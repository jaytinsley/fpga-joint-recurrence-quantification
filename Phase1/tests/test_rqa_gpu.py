"""GPU RQA extraction equals the CPU reference (convention "rtl") exactly on integers and to 1e-12 on floats."""
import numpy as np
import pytest

cp = pytest.importorskip("cupy")

from jrp.rqa import rqa_metrics  # noqa: E402
from jrp.rqa_gpu import rqa_metrics_gpu  # noqa: E402


def _sym(n, p, rng):
    a = np.triu(rng.random((n, n)) < p, 1)
    return (a | a.T).astype(np.uint8)


@pytest.mark.parametrize("n", [5, 17, 64, 300])
@pytest.mark.parametrize("p", [0.0, 0.02, 0.3, 0.9, 1.0])
def test_random_matrices(n, p):
    R = _sym(n, p, np.random.default_rng(n * 7 + int(p * 100)))
    a, b = rqa_metrics(R, 2, 2, "rtl"), rqa_metrics_gpu(cp.asarray(R), 2, 2)
    for k in a:
        assert a[k] == b[k] if k in ("Lmax", "Vmax") else abs(a[k] - b[k]) < 1e-12


@pytest.mark.parametrize("lmin", [2, 3, 5])
def test_structured_and_min_lengths(lmin):
    s = np.sin(np.arange(900) * 0.2)
    R = (np.abs(s[:, None] - s[None, :]) < 0.2).astype(np.uint8)
    a, b = rqa_metrics(R, lmin, lmin, "rtl"), rqa_metrics_gpu(cp.asarray(R), lmin, lmin)
    for k in a:
        assert a[k] == b[k] if k in ("Lmax", "Vmax") else abs(a[k] - b[k]) < 1e-12
