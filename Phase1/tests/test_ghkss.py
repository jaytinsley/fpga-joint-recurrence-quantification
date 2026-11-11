import numpy as np
import pytest

from jrp.ghkss import delay_vectors, ghkss
from jrp.signals import gen_lorenz_x_resampled


def rms(a, b):
    return float(np.sqrt(np.mean((a - b) ** 2)))


def logistic(n, r=3.9, x0=0.3):
    x = np.empty(n + 100)
    x[0] = x0
    for i in range(1, n + 100):
        x[i] = r * x[i - 1] * (1 - x[i - 1])
    return x[100:]


def test_delay_vectors_hand_checked():
    Z = delay_vectors(np.arange(6.0), m=3, tau=2)
    assert Z.tolist() == [[0, 2, 4], [1, 3, 5]]


def test_bad_arguments():
    with pytest.raises(ValueError):
        ghkss(np.zeros(100), m=3, q=3)
    with pytest.raises(ValueError):
        delay_vectors(np.zeros(4), 3, 2)


def test_reduces_noise_on_logistic_map():
    x = logistic(2000)
    sig = 0.01
    y = x + sig * np.random.default_rng(0).standard_normal(len(x))
    z = ghkss(y, m=5, tau=1, q=1, k_min=30, eps=3 * sig * np.sqrt(5))
    assert z.shape == y.shape
    assert rms(z, x) < 0.5 * rms(y, x)


def test_reduces_noise_on_lorenz():
    x = gen_lorenz_x_resampled(2000, 40.0, 0.01)
    x = x / x.std()
    sig = 0.3
    y = x + sig * np.random.default_rng(0).standard_normal(len(x))
    z = ghkss(y, m=7, tau=2, q=3, k_min=30, eps=2 * sig * np.sqrt(7))
    assert rms(z, x) < 0.7 * rms(y, x)


def test_clean_signal_barely_changes_and_is_deterministic():
    x = logistic(1000)
    z1 = ghkss(x, m=5, tau=1, q=1, k_min=30, eps=0.05)
    z2 = ghkss(x, m=5, tau=1, q=1, k_min=30, eps=0.05)
    assert np.array_equal(z1, z2)
    # A local linear projection leaves a small curvature bias on a clean parabola map
    # (about 0.5 % of the signal range here); it must stay well below typical noise levels.
    assert rms(z1, x) < 1e-2
