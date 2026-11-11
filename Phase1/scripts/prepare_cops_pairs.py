"""Cut two-column segment files from Capstone/cops_iridomyrmex.mat for scripts/export_insect_golden.py.

The four series in that file are SEPARATE recordings (not simultaneous), 12 kHz, 2,097,152 samples each, unfiltered. The
variable purpureus_wild is a straight 0..1 ramp (export error) and is refused. Each pair file holds the same sample index
range of two different recordings, so a joint recurrence plot of it compares two unrelated systems: use it as a hardware
validation case and independence baseline, not as a coupling measurement.

Usage: python prepare_cops_pairs.py [--start-s 5.0] [--n 4096]
Writes data/raw/cops_<a>__<b>_s<start>_n<N>.npy (N x 2, float64) and prints the export command for each pair.
"""
import argparse
from pathlib import Path

import numpy as np
from scipy.io import loadmat

ROOT = Path(__file__).resolve().parents[1]
MAT = ROOT.parent / "cops_iridomyrmex.mat"
FS = 12000
PAIRS = [("acinaciformis_Darwin", "purpureus_lab"), ("acinaciformis_Griffith", "purpureus_lab"),
         ("acinaciformis_Darwin", "acinaciformis_Griffith")]


def is_ramp(x):
    dev = np.max(np.abs(x - np.linspace(x[0], x[-1], len(x))))
    return dev < 1e-3 * (x.max() - x.min())


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--start-s", type=float, default=5.0)
    a.add_argument("--n", type=int, default=4096)
    args = a.parse_args()
    d = loadmat(MAT, squeeze_me=True)
    out = ROOT / "data" / "raw"
    out.mkdir(parents=True, exist_ok=True)
    s0 = int(round(args.start_s * FS))
    for na, nb in PAIRS:
        for nm in (na, nb):
            if is_ramp(d[nm]):
                raise SystemExit(f"{nm} is a straight ramp, not a signal")
        seg = np.stack([d[na][s0:s0 + args.n], d[nb][s0:s0 + args.n]], axis=1).astype(np.float64)
        f = out / f"cops_{na}__{nb}_s{s0}_n{args.n}.npy"
        np.save(f, seg)
        short = lambda s: s.split("_")[-1].lower()
        name = f"insect_{short(na)}_{short(nb)}"
        print(f"{f.name}: {seg.shape}, channels x={na}, y={nb}")
        print(f"  python scripts/export_insect_golden.py --file data/raw/{f.name} --fs {FS} --cx 0 --cy 1 --n {args.n} "
              f"--start 0 --eps-percent 10 --name {name} --label \"cops_iridomyrmex.mat, separate recordings\"")


if __name__ == "__main__":
    main()
