"""Golden cases for the band-passed, decimated footstep test on the board.
Per series (Darwin termite, Griffith termite, lab ant): detect footsteps with an envelope detector, rank the 51 windows
(start every 3 s from 10 s to 160 s, 4096 samples at 3 kHz = 1.365 s), keep the 10 most footstep-rich ("f": most events, ties by
peak-to-floor ratio) and the 10 quietest ("q": fewest events, ties by lowest peak-to-floor ratio). Same samples in both channels,
m=5, tau=2, 5% recurrence-rate threshold, gain to eps 0.3. Writes golden/wt_<series>_<start_s>_<f|q>.* and golden/termite_cases.txt.

Detector (the author's reading of an envelope method; not verified against Oberst, Lai and Evans 2026): zero-phase 700 to 1500 Hz
Butterworth band-pass, Hilbert envelope smoothed by a 5 ms moving average, noise floor = median envelope, sigma = 1.4826*MAD,
event = upward crossing of floor + 8 sigma, refractory 50 ms.
"""
import csv
import sys
from pathlib import Path

import numpy as np
from scipy.io import loadmat
from scipy.signal import butter, hilbert, resample_poly, sosfiltfilt
from scipy.spatial.distance import pdist

from jrp.embedding import takens_embedding
from jrp.golden import export_case
from jrp.jrp import ChannelParams

ROOT = Path(__file__).resolve().parents[1]
FS, F, N, M, TAU, KSIG, NSEL = 12000, 4, 4096, 5, 2, 8.0, 10
SPAN = N * F
SERIES = (("darwin", "acinaciformis_Darwin"), ("griffith", "acinaciformis_Griffith"), ("lab", "purpureus_lab"), ("wild", "purpureus_wild"))
ONLY = sys.argv[1:]                               # optional series tags, e.g. "wild": then only those are exported
if ONLY:
    SERIES = tuple(t for t in SERIES if t[0] in ONLY)
else:
    SERIES = SERIES[:3]                            # default: the original three series
SUFFIX = "_" + "_".join(ONLY) if ONLY else ""
STARTS = np.arange(10, 160.1, 3.0)
d = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)
sos = butter(4, [700, 1500], btype="bandpass", fs=FS, output="sos")
names, table = [], []
for tag, var in SERIES:
    x = d[var].astype(float)
    x -= x.mean()
    bp = sosfiltfilt(sos, x)
    env = np.convolve(np.abs(hilbert(bp)), np.ones(60) / 60, "same")
    fl = np.median(env)
    thr = fl + KSIG * 1.4826 * np.median(np.abs(env - fl))
    up = np.flatnonzero((env[1:] > thr) & (env[:-1] <= thr)) + 1
    ev = []
    for u in up:
        if not ev or u - ev[-1] > 600:
            ev.append(u)
    ev = np.array(ev)
    cnt = np.array([((ev >= int(s * FS)) & (ev < int(s * FS) + SPAN)).sum() for s in STARTS])
    pk = np.array([env[int(s * FS):int(s * FS) + SPAN].max() / fl for s in STARTS])
    order = np.lexsort((pk, cnt))                      # ascending by count, then peak
    groups = {"q": order[:NSEL], "f": order[::-1][:NSEL]}
    dec = resample_poly(bp, 1, F)
    for g, idx in groups.items():
        for wi in sorted(idx):
            s = int(STARTS[wi])
            w = dec[int(s * FS) // F:int(s * FS) // F + N]
            w = (w - w.min()) / (w.max() - w.min())
            eps = float(np.quantile(pdist(takens_embedding(w, M, TAU)), 0.05))
            gain = float(np.clip(0.3 / eps, 1.0, 100.0))
            p = ChannelParams(M, TAU, eps=eps * gain)
            name = f"wt_{tag}_{s}_{g}"
            export_case(name, ROOT / "golden", w * gain, w * gain, p, p, lmin=2, vmin=2,
                        source={"dataset": var, "start_s": s, "filter": "700-1500 Hz band-pass, decimate 4", "group": g,
                                "events": int(cnt[wi]), "peak_to_floor": float(pk[wi]), "target_rr": 0.05, "gain": gain})
            names.append(name)
            table.append((tag, s, g, int(cnt[wi]), float(pk[wi])))
(ROOT / "golden" / f"termite_cases{SUFFIX}.txt").write_text("\n".join(names) + "\n")
with open(ROOT / "results" / f"termite_case_selection{SUFFIX}.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["series", "start_s", "group", "events", "peak_to_floor"])
    w.writerows(table)
print(len(names), "cases")
