"""Rerun of the termite noise test with the review fixes.
Fixes: (1) kurtosis selection uses the same time span as the analysed window (4096 samples at 3 kHz = 16384 at 12 kHz);
(2) 20 phase-randomised surrogates per window; (3) bootstrap 95% interval of the group mean excess and a Mann-Whitney test.
Conditions: dec4 = raw decimated by 4 (anti-alias, 0 to 1.5 kHz); bp_dec4 = 700 to 1500 Hz band-pass then decimate by 4.
Windows: 51 per series, start every 3 s from 10 to 160 s (non-overlapping), 4096 samples at 3 kHz (1.365 s). m=5, 5% recurrence rate, rtl convention.
"""
import csv, sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import numpy as np
from scipy.io import loadmat
from scipy.signal import butter, resample_poly, sosfiltfilt
from scipy.spatial.distance import pdist
from scipy.stats import kurtosis, mannwhitneyu

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from jrp.embedding import select_tau, takens_embedding  # noqa: E402
from jrp.jrp import ChannelParams  # noqa: E402
from jrp.pipeline import jrp_rqa  # noqa: E402

OUT = ROOT / "results"
FS, N, M, F = 12000, 4096, 5, 4
SERIES = {"Darwin termite": "acinaciformis_Darwin", "Griffith termite": "acinaciformis_Griffith", "lab ant": "purpureus_lab"}
STARTS_S = np.arange(10, 160.1, 3.0)
CONDS = ["dec4", "bp_dec4"]
NSURR = 20


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


def boot(v, rng, B=4000):
    m = [rng.choice(v, len(v)).mean() for _ in range(B)]
    return np.percentile(m, [2.5, 97.5])


def main():
    d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
    sos = butter(4, [700, 1500], btype="bandpass", fs=FS, output="sos")
    jobs, keys, kurt, taus = [], [], {}, {}
    for si, (name, var) in enumerate(SERIES.items()):
        raw = d[var].astype(float); raw -= raw.mean()
        bp = sosfiltfilt(sos, raw)
        ser = {"dec4": resample_poly(raw, 1, F), "bp_dec4": resample_poly(bp, 1, F)}
        span = N * F
        kurt[name] = np.array([kurtosis(bp[int(s * FS):int(s * FS) + span]) for s in STARTS_S])
        for c in CONDS:
            x = ser[c]; st0 = int(60 * FS) // F
            taus[(name, c)] = min(select_tau(x[st0:st0 + N], maxtau=40), 16)
            for wi, s in enumerate(STARTS_S):
                st = int(s * FS) // F
                jobs.append((x[st:st + N].copy(), taus[(name, c)], 1000 * si + wi))
                keys.append((name, c, wi))
    del d
    with ProcessPoolExecutor(max_workers=12) as ex:
        res = list(ex.map(one, jobs, chunksize=4))
    with open(OUT / "termite_noise_test2.csv", "w", newline="") as f:
        w = csv.writer(f); w.writerow(["series", "condition", "window", "start_s", "kurtosis", "tau", "DET", "DET_surr_mean", "DET_surr_sd"])
        for (n, c, wi), r in zip(keys, res):
            w.writerow([n, c, wi, STARTS_S[wi], kurt[n][wi], taus[(n, c)], *r])
    rng = np.random.default_rng(1)
    out = ["# Termite noise test, rerun (matched duration, 20 surrogates)", "",
           f"51 windows per series, 4096 samples at 3 kHz (1.365 s), kurtosis taken over the same span, m={M}, 5% recurrence rate, {NSURR} surrogates per window.",
           "Footstep-like = top quarter by kurtosis (13 windows), quiet = bottom quarter (13). Excess = DET minus mean surrogate DET: mean [95% bootstrap interval], median.",
           "z = excess / surrogate SD (per window); p = Mann-Whitney footstep-like vs quiet excess (one-sided).", "",
           "| series | condition | tau | group | mean excess [95% CI] | median | windows with excess > 2 surr. SD | p vs quiet |", "|---|---|---|---|---|---|---|---|"]
    for name in SERIES:
        k = kurt[name]; hi = k >= np.percentile(k, 75); lo = k <= np.percentile(k, 25)
        for c in CONDS:
            R = np.array([r for (n, cc, wi), r in zip(keys, res) if n == name and cc == c])
            ex_ = R[:, 0] - R[:, 1]; z = ex_ / R[:, 2]
            p = mannwhitneyu(ex_[hi], ex_[lo], alternative="greater").pvalue
            for lab, sel in (("all", np.ones(len(k), bool)), ("footstep-like", hi), ("quiet", lo)):
                v = ex_[sel]; ci = boot(v, rng)
                out.append(f"| {name} | {c} | {taus[(name, c)]} | {lab} | {v.mean():.3f} [{ci[0]:.3f}, {ci[1]:.3f}] | {np.median(v):.3f} | {(z[sel] > 2).sum()}/{sel.sum()} | {p:.3f} |" if lab == "footstep-like" else
                           f"| {name} | {c} | {taus[(name, c)]} | {lab} | {v.mean():.3f} [{ci[0]:.3f}, {ci[1]:.3f}] | {np.median(v):.3f} | {(z[sel] > 2).sum()}/{sel.sum()} | |")
    (OUT / "termite_noise_test2.md").write_text("\n".join(out) + "\n", encoding="utf8")
    print("\n".join(out))


if __name__ == "__main__":
    main()
