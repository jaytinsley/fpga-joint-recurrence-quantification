"""Run after termite_noise_test.py. Envelope-based footstep detection and regrouping of the rerun windows (no DET recomputation).
Detector (author's reading, not verified against Oberst, Lai and Evans 2026): 700-1500 Hz zero-phase band-pass,
Hilbert envelope smoothed by a 5 ms moving average, noise floor = median of the envelope over the whole recording,
sigma = 1.4826*MAD, event = upward crossing of floor + 8 sigma, refractory 50 ms. Window score = events in the window span (1.365 s)
and peak-to-floor ratio."""
import csv, sys
from pathlib import Path
import numpy as np
from scipy.io import loadmat
from scipy.signal import butter, sosfiltfilt, hilbert
from scipy.stats import mannwhitneyu
ROOT = Path(__file__).resolve().parents[1]
FS, SPAN = 12000, 16384
SERIES = {"Darwin termite": "acinaciformis_Darwin", "Griffith termite": "acinaciformis_Griffith", "lab ant": "purpureus_lab"}
STARTS = np.arange(10, 160.1, 3.0)
K = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
sos = butter(4, [700, 1500], btype="bandpass", fs=FS, output="sos")
rows = list(csv.DictReader(open(ROOT / "results" / "termite_noise_test2.csv")))
rng = np.random.default_rng(2)
out = []
score = {}
for name, var in SERIES.items():
    x = d[var].astype(float); x -= x.mean()
    env = np.abs(hilbert(sosfiltfilt(sos, x)))
    env = np.convolve(env, np.ones(60) / 60, "same")
    fl = np.median(env); sg = 1.4826 * np.median(np.abs(env - fl)); thr = fl + K * sg
    up = np.flatnonzero((env[1:] > thr) & (env[:-1] <= thr)) + 1
    ev = []
    for u in up:
        if not ev or u - ev[-1] > 600: ev.append(u)
    ev = np.array(ev)
    print(name, "events", len(ev), "rate/s %.2f" % (len(ev) / (len(x) / FS)), "floor %.2e sigma %.2e" % (fl, sg))
    cnt = np.array([((ev >= int(s * FS)) & (ev < int(s * FS) + SPAN)).sum() for s in STARTS])
    pk = np.array([env[int(s * FS):int(s * FS) + SPAN].max() / fl for s in STARTS])
    score[name] = (cnt, pk)
    for c in ("bp_dec4", "dec4"):
        r = [q for q in rows if q["series"] == name and q["condition"] == c]
        ex = np.array([float(q["DET"]) - float(q["DET_surr_mean"]) for q in r])
        hi = cnt >= max(1, np.percentile(cnt, 75)); lo = cnt == 0 if (cnt == 0).sum() >= 5 else cnt <= np.percentile(cnt, 25)
        if hi.sum() < 3 or lo.sum() < 3: print("  too few", c, hi.sum(), lo.sum()); continue
        p = mannwhitneyu(ex[hi], ex[lo], alternative="greater").pvalue
        rho = np.corrcoef(np.argsort(np.argsort(pk)), np.argsort(np.argsort(ex)))[0, 1]
        m = lambda v: (v.mean(), *np.percentile([rng.choice(v, len(v)).mean() for _ in range(3000)], [2.5, 97.5]))
        out.append(f"| {name} | {c} | events {cnt.sum()}, windows with events {(cnt>0).sum()}/51 | top quarter by event count (min 1) ({hi.sum()}): {m(ex[hi])[0]:.3f} [{m(ex[hi])[1]:.3f}, {m(ex[hi])[2]:.3f}] | event-free (or bottom quarter if fewer than 5) ({lo.sum()}): {m(ex[lo])[0]:.3f} [{m(ex[lo])[1]:.3f}, {m(ex[lo])[2]:.3f}] | p={p:.3f} | rank corr peak/floor vs excess {rho:.2f} |")
print("\n".join(out))
