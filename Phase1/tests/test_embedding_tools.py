import numpy as np

from jrp.embedding import (ami, first_local_minimum, fnn_fractions, select_dim,
                           select_tau)
from jrp.signals import gen_lorenz_x_resampled, gen_uwn


def test_first_local_minimum_hand_checked():
    assert first_local_minimum([5, 4, 3, 4, 5, 2, 6]) == 2
    assert first_local_minimum([3, 2, 1, 0]) == -1  # monotone: no interior minimum
    # noise bump at index 2 is removed by smoothing
    assert first_local_minimum([9, 5, 6, 5, 4, 3, 4, 9, 9], smooth=1) == 1
    assert first_local_minimum([9, 5, 6, 5, 4, 3, 4, 9, 9], smooth=3) == 5


def test_ami_is_max_at_lag_zero_and_low_for_noise():
    x = gen_uwn(4096, seed=1)
    mi = ami(x, maxtau=20)
    assert mi[0] > 4 * mi[1:].max()


def test_lorenz_delay_and_dimension():
    x = gen_lorenz_x_resampled(4096)  # dt = 100 / 4095 s
    tau = select_tau(x, maxtau=100)
    assert 5 <= tau <= 9
    f = fnn_fractions(x, tau, range(1, 7))
    assert f[0] > 0.9 and f[2] < 0.05 and f[5] < 0.01  # FNN collapses by m = 3
    assert select_dim(x, tau, max_dim=8) == 3


def test_noise_never_unfolds():
    x = gen_uwn(2048, seed=7)
    assert select_dim(x, 1, max_dim=6) == 6
