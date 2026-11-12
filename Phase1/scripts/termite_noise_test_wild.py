"""Wild-ant addition to the footstep-resolved test: band-pass 700 to 1500 Hz, decimate by 4, 51 windows (every 3 s from 10 to 160 s),
DET and the mean of 20 phase-randomised surrogates per window (m=5, 5% recurrence rate, rtl). Same method as termite_noise_test.py.
Writes results/termite_noise_test_wild.csv in the same columns (condition bp_dec4 only)."""
import csv
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
from scipy.io import loadmat
from scipy.signal import butter, resample_poly, sosfiltfilt
from scipy.spatial.distance import pdist

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from jrp.embedding import select_tau, takens_embedding  # noqa: E402
from jrp.jrp import ChannelParams  # noqa: E402
from jrp.pipeline import jrp_rqa  # noqa: E402

FS, N, M, F, NSURR = 12000, 4096, 5, 4, 20
STARTS_S = np.arange(10, 160.1, 3.0)


def phase_randomise(x, rng):
    X = np.fft.rfft(x)
    ph = rng.uniform(0, 2 * np.pi, len(X)); ph[0] = 0
    if len(x) % 2 == 0:
        ph[-1] = 0
    return np.fft.irfft(np.abs(X) * np.exp(1j * ph), n=len(x))


def det_of(x, tau):
    x = (x - x.min()) / (x.max() - x.min())
    eps = float(np.quantile(pdist(takens_embedding(x, M, tau)), 0.05))
    p = ChannelParams(M, tau, eps=eps)
    r, _ = jrp_rqa(x, x, p, p, lmin=2, vmin=2, convention="rtl", normalise=False)
    return r["JDET"]


def one(a):
    x, tau, seed = a
    rng = np.random.default_rng(seed)
    d = det_of(x, tau)
    s = np.array([det_of(phase_randomise(x, rng), tau) for _ in range(NSURR)])
    return d, s.mean(), s.std(ddof=1)


def main():
    d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
    raw = d["purpureus_wild"].astype(float); raw -= raw.mean()
    sos = butter(4, [700, 1500], btype="bandpass", fs=FS, output="sos")
    x = resample_poly(sosfiltfilt(sos, raw), 1, F)
    st0 = int(60 * FS) // F
    tau = 2                                  # as for the other series and the board cases (the mutual-information choice for the wild ant is 5; reported in the CSV)
    tau_ami = min(select_tau(x[st0:st0 + N], maxtau=40), 16)
    jobs = [(x[int(s * FS) // F:int(s * FS) // F + N].copy(), tau, 3000 + wi) for wi, s in enumerate(STARTS_S)]
    with ProcessPoolExecutor(max_workers=12) as ex:
        res = list(ex.map(one, jobs, chunksize=2))
    with open(ROOT / "results" / "termite_noise_test_wild.csv", "w", newline="") as f:
        w = csv.writer(f); w.writerow(["series", "condition", "window", "start_s", "kurtosis", "tau", "DET", "DET_surr_mean", "DET_surr_sd"])
        for wi, r in enumerate(res):
            w.writerow(["wild ant", "bp_dec4", wi, STARTS_S[wi], "", tau, *r])
    print("tau", tau, "AMI tau", tau_ami, "mean DET", np.mean([r[0] for r in res]), "mean excess", np.mean([r[0] - r[1] for r in res]))


if __name__ == "__main__":
    main()
