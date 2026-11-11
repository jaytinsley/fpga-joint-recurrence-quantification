"""Task 8/10: turn a simultaneously recorded insect channel pair into a golden case that the RTL
simulation (Phase3/scripts/sim_top.ps1) and the board (Phase3/scripts/run_insect.ps1) can run.

Steps: load (src/jrp/insect.py) -> mean removal, optional decimation, cut n samples, scale each
channel to [0, 1] -> choose (tau, m) per channel (AMI first minimum, false nearest neighbours; or
your own values) -> Q8.24 quantise, integer JRP, counters, JSON sidecar via jrp.golden.export_case.

The hardware build (jrp_top MAX_M = 6, MAX_TAU = 16, N_MAX = 8192) bounds what it can run. This script
stops with a clear message if the chosen parameters exceed it, rather than exporting a case that the
board would silently get wrong. Choose a larger --decimate, or give --tau-x/--m-x yourself.

Example:
  python scripts/export_insect_golden.py --file data/raw/pair01.wav --cx 0 --cy 1 --n 4096 \
         --decimate 4 --eps-percent 50 --name insect_pair01
  python scripts/export_insect_golden.py --file data/raw/pair01.csv --fs 20000 --cx LDV --cy MIC ...
Output: golden/<name>*.hex, golden/<name>.json (+ golden/<name>_selection.json with the choices and the
scale factors back to physical units).
"""
import argparse
import json
from pathlib import Path

from jrp.embedding import select_dim, select_tau
from jrp.golden import export_case
from jrp.insect import load_recording, preprocess_pair
from jrp.jrp import ChannelParams

HW_MAX_M, HW_MAX_TAU, HW_N_MAX = 6, 16, 8192
OUT = Path(__file__).resolve().parents[1] / "golden"


def main():
    a = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument("--file", required=True)
    a.add_argument("--fs", type=float, default=None, help="sampling rate Hz (not needed for WAV or CSV with a time column)")
    a.add_argument("--units", default="unknown")
    a.add_argument("--delimiter", default=None)
    a.add_argument("--mat-var", default=None)
    a.add_argument("--cx", default="0", help="channel for x (index or name)")
    a.add_argument("--cy", default="1", help="channel for y (index or name)")
    a.add_argument("--n", type=int, default=4096, help="samples per channel after decimation (N)")
    a.add_argument("--start", type=int, default=0, help="first sample after decimation")
    a.add_argument("--decimate", type=int, default=1)
    a.add_argument("--m-x", type=int, default=None)
    a.add_argument("--m-y", type=int, default=None)
    a.add_argument("--tau-x", type=int, default=None)
    a.add_argument("--tau-y", type=int, default=None)
    a.add_argument("--eps-percent", type=float, default=50.0, help="threshold as %% of the max embedded distance, both channels")
    a.add_argument("--eps-percent-y", type=float, default=None)
    a.add_argument("--lmin", type=int, default=2)
    a.add_argument("--vmin", type=int, default=2)
    a.add_argument("--max-tau-search", type=int, default=100)
    a.add_argument("--label", default="insect recording pair", help="dataset description stored in the JSON")
    a.add_argument("--hw-max-m", type=int, default=HW_MAX_M, help="MAX_M of the bitstream that will run the case (6, or 10 for the _m10 build)")
    a.add_argument("--name", required=True)
    args = a.parse_args()

    def chan(c):
        return int(c) if str(c).lstrip("-").isdigit() else c

    rec = load_recording(args.file, fs=args.fs, units=args.units, csv_delimiter=args.delimiter, mat_var=args.mat_var)
    x_raw, y_raw = rec.pair(chan(args.cx), chan(args.cy))
    x, y, info = preprocess_pair(x_raw, y_raw, rec.fs, args.n, args.start, args.decimate)
    print(f"{args.file}: fs {rec.fs:g} Hz -> {info['fs_out_Hz']:g} Hz, {args.n} samples from {args.start}")

    sel = {}
    for tag, sig, m_arg, tau_arg in (("x", x, args.m_x, args.tau_x), ("y", y, args.m_y, args.tau_y)):
        tau = tau_arg if tau_arg is not None else select_tau(sig, maxtau=args.max_tau_search)
        m = m_arg if m_arg is not None else select_dim(sig, tau, max_dim=10)
        sel[tag] = {"m": int(m), "tau": int(tau), "tau_auto": tau_arg is None, "m_auto": m_arg is None}
        print(f"  channel {tag}: tau {tau}{' (AMI)' if tau_arg is None else ''}, m {m}{' (FNN)' if m_arg is None else ''}")

    problems = []
    for tag in "xy":
        if sel[tag]["m"] > args.hw_max_m:
            problems.append(f"m_{tag} = {sel[tag]['m']} exceeds the hardware MAX_M = {args.hw_max_m}")
        if sel[tag]["tau"] > HW_MAX_TAU:
            problems.append(f"tau_{tag} = {sel[tag]['tau']} exceeds the hardware MAX_TAU = {HW_MAX_TAU} "
                            f"(try --decimate {max(2, -(-sel[tag]['tau'] // HW_MAX_TAU) * args.decimate // 1)} or higher)")
    if args.n > HW_N_MAX:
        problems.append(f"n = {args.n} exceeds N_MAX = {HW_N_MAX}")
    if problems:
        raise SystemExit("cannot run on the current hardware build:\n  " + "\n  ".join(problems))

    px = ChannelParams(sel["x"]["m"], sel["x"]["tau"], eps_percent=args.eps_percent)
    py = ChannelParams(sel["y"]["m"], sel["y"]["tau"],
                       eps_percent=args.eps_percent_y if args.eps_percent_y is not None else args.eps_percent)
    source = {"dataset": args.label, "file": str(args.file), "fs_Hz": rec.fs, "units": rec.units,
              "channels": [str(args.cx), str(args.cy)], "preprocess": info, "normalised": "[0,1] per channel"}
    side = export_case(args.name, OUT, x, y, px, py, lmin=args.lmin, vmin=args.vmin, source=source)
    (OUT / f"{args.name}_selection.json").write_text(json.dumps(
        {"selection": sel, "eps_percent_x": px.eps_percent, "eps_percent_y": py.eps_percent, "preprocess": info,
         "source_file": str(args.file), "fs_Hz": rec.fs, "units": rec.units}, indent=2))
    print("n_vectors", side["n_vectors"], "expected", side["expected_metrics"])
    print(f"golden case written: {OUT / (args.name + '.json')}")
    print(f"next: simulate  Phase3\\scripts\\sim_top.ps1 -Case {args.name} -K 2   (optional)")
    print(f"      board     Phase3\\scripts\\run_insect.ps1 -Case {args.name}")


if __name__ == "__main__":
    main()
