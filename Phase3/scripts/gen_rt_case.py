"""Prepare a real-time (DMA) hardware run of golden cases.

Writes build/rtcase/<name>.bin: NREP copies of the case's samples as 8-byte little-endian words {y[31:0], x[31:0]}
(the format the AXI-DMA streams into jrp_rt_core), to be placed in PS on-chip memory (OCM, 0xFFFC0000, 256 KB =
32768 time steps), and build/hwcase/<case>.tcl (via gen_hw_case.py) for the expected counters.
Usage: python gen_rt_case.py <case> [--nrep 3]
"""
import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_hw_case  # noqa: E402

OCM_STEPS = 32768


def main():
    a = argparse.ArgumentParser()
    a.add_argument("case")
    a.add_argument("--nrep", type=int, default=3)
    args = a.parse_args()
    gen_hw_case.gen(args.case)
    gold = gen_hw_case.GOLD
    x = gen_hw_case.words(gold / f"{args.case}_x.hex")
    ypath = gold / f"{args.case}_y.hex"
    y = gen_hw_case.words(ypath) if ypath.exists() else ["00000000"] * len(x)
    total = len(x) * args.nrep
    if total > OCM_STEPS:
        raise SystemExit(f"{total} time steps do not fit the OCM ({OCM_STEPS}); use --nrep {OCM_STEPS // len(x)} or less")
    out = Path(__file__).resolve().parents[1] / "build" / "rtcase"
    out.mkdir(parents=True, exist_ok=True)
    buf = bytearray()
    for _ in range(args.nrep):
        for xv, yv in zip(x, y):
            buf += struct.pack("<II", int(xv, 16), int(yv, 16))
    (out / f"{args.case}.bin").write_bytes(bytes(buf))
    print(f"{args.case}: {len(x)} samples x {args.nrep} windows = {len(buf)} bytes -> {out / (args.case + '.bin')}")


if __name__ == "__main__":
    main()
