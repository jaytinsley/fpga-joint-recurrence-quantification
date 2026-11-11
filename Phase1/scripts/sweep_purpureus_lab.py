"""Stability sweep for purpureus_lab (AccRQA/Marwan advice: sweep (m, tau) and check stability; threshold by target recurrence rate).
Per segment: DET, LAM, ENTR over m x tau at a fixed single-channel RR (1% and 5%), and against shuffled and phase-randomised surrogates
at the AMI/FNN choice. Prints tables, writes results/purpureus_lab_sweep.md.
"""
from pathlib import Path

import numpy as np
from scipy.io import loadmat

from jrp.embedding import takens_embedding
from jrp.jrp import recurrence_matrix_blocked
from jrp.rqa import rqa_metrics

ROOT = Path(__file__).resolve().parents[1]
FS, N = 12000, 4096
rng = np.random.default_rng(1)


def eps_for_rr(V, rr, ns=1200):
    idx = rng.choice(len(V), min(ns, len(V)), replace=False)
    D = np.sqrt(((V[idx][:, None, :] - V[idx][None, :, :]) ** 2).sum(-1))
    return np.percentile(D[np.triu_indices(len(idx), 1)], 100 * rr)


def run(x, m, tau, rr, theiler=True):
    V = takens_embedding(x, m, tau)
    R = recurrence_matrix_blocked(V, eps_for_rr(V, rr))
    if theiler:  # exclude the corridor |i-j| <= (m-1) tau around the main diagonal
        w = (m - 1) * tau
        i = np.arange(len(V))
        R = R.copy(); R[np.abs(i[:, None] - i[None, :]) <= w] = 0
    k = rqa_metrics(R, 2, 2, "rtl")
    return k["RR"], k["DET"], k["LAM"], k["ENTR"]


def phase_random(x):
    X = np.fft.rfft(x - x.mean())
    ph = rng.uniform(0, 2 * np.pi, len(X)); ph[0] = 0
    return np.fft.irfft(np.abs(X) * np.exp(1j * ph), len(x)) + x.mean()


def main():
    full = loadmat(ROOT.parent / "cops_iridomyrmex.mat", squeeze_me=True)["purpureus_lab"].astype(float)
    # activity: rms in 4096-blocks; footstep-rich = highest, quiet = lowest
    nb = len(full) // N
    rms = np.array([full[b * N:(b + 1) * N].std() for b in range(nb)])
    segs = {"footsteps (5.0 s)": 5 * FS, "busiest block": int(np.argmax(rms)) * N, "quietest block": int(np.argmin(rms)) * N}
    out = ["# purpureus_lab (m, tau) stability sweep", "", f"N={N}, Theiler corridor (m-1)tau, rtl convention, lmin=vmin=2.", ""]
    for name, s0 in segs.items():
        x = full[s0:s0 + N]; x = (x - x.min()) / (x.max() - x.min())
        out += [f"## {name} (start {s0 / FS:.2f} s, rms {x.std():.4f})", ""]
        for rr in (0.01, 0.05):
            out += [f"Target RR {rr:.0%}: DET / LAM / ENTR", "", "| m \\ tau | 1 | 2 | 4 | 8 |", "|---|---|---|---|---|"]
            for m in (2, 3, 5, 7, 10):
                cells = []
                for tau in (1, 2, 4, 8):
                    _, d, l, e = run(x, m, tau, rr)
                    cells.append(f"{d:.2f} / {l:.2f} / {e:.2f}")
                out.append(f"| {m} | " + " | ".join(cells) + " |")
            out.append("")
        # surrogates at m=5 tau=4, RR 5%
        base = run(x, 5, 4, 0.05)
        sh = np.array([run(rng.permutation(x), 5, 4, 0.05) for _ in range(8)])
        pr = np.array([run(phase_random(x), 5, 4, 0.05) for _ in range(8)])
        out += ["m=5, tau=4, RR 5%: original vs surrogates (mean +/- sd of 8)", "", "| | DET | LAM | ENTR |", "|---|---|---|---|",
                f"| original | {base[1]:.3f} | {base[2]:.3f} | {base[3]:.3f} |",
                f"| shuffled | " + " | ".join(f"{sh[:, k].mean():.3f} +/- {sh[:, k].std():.3f}" for k in (1, 2, 3)) + " |",
                f"| phase-randomised | " + " | ".join(f"{pr[:, k].mean():.3f} +/- {pr[:, k].std():.3f}" for k in (1, 2, 3)) + " |", ""]
        print("\n".join(out[-24:]))
    (ROOT / "results" / "purpureus_lab_sweep.md").write_text("\n".join(out) + "\n", encoding="utf8")


if __name__ == "__main__":
    main()
