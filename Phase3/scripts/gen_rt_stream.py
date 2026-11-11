"""Streaming golden set: a long two-channel SYNTHETIC signal (Lorenz x and z, Phase 1 integrator) cut into
NWIN consecutive non-overlapping windows of N_RAW samples, with the exact integer counters and histograms the
hardware must report for every window.

Why not the usual per-window threshold: the hardware takes eps2 from a register. A real-time system cannot recompute
"percent of the maximum distance" per window, so one fixed eps2 per channel is used for the whole stream, taken from
the first window (percent of its maximum distance), as a PS driver would do. Everything else follows the Phase 1
integer model (Q8.24, end alignment, rtl counters).

Writes build/rtcase/<name>.bin (OCM image, {y, x} 8-byte words, little endian) and build/hwcase/<name>.tcl
(static fields as gen_hw_case.py, plus case(nwin) and per-window wexp/wdet/wlam arrays) for scripts/hw_rt_run.tcl.
Usage: python gen_rt_stream.py --name rt_stream_demo --nraw 4096 --nwin 6 [--m 3 --tau 4 --eps-percent 20]
"""
import argparse
import struct
import sys
from pathlib import Path

import numpy as np

P3 = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(P3.parent / "Phase1" / "src"))
from jrp import fixedpoint as fp  # noqa: E402
from jrp.jrp import ChannelParams, embed_pair, resolve_eps  # noqa: E402
from jrp.rqa import rtl_counters  # noqa: E402
from jrp.signals import integrate_lorenz, resample_to_length, to_unit_interval  # noqa: E402

OCM_STEPS = 32768


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--name", default="rt_stream_demo")
    a.add_argument("--nraw", type=int, default=4096)
    a.add_argument("--nwin", type=int, default=6)
    a.add_argument("--m", type=int, default=3)
    a.add_argument("--tau", type=int, default=2)
    a.add_argument("--eps-percent", type=float, default=8.0)
    args = a.parse_args()
    total = args.nraw * args.nwin
    if total > OCM_STEPS:
        raise SystemExit(f"{total} time steps exceed the OCM ({OCM_STEPS})")
    T = total * 0.06                       # 0.02 time units per sample, about 37 samples per Lorenz revolution
    t, lx, ly, lz = integrate_lorenz(total_time=T, dt=0.01)
    x = to_unit_interval(resample_to_length(t, lx, total, T))
    y = to_unit_interval(resample_to_length(t, lz, total, T))
    px = ChannelParams(args.m, args.tau, eps_percent=args.eps_percent)
    py = ChannelParams(args.m, args.tau, eps_percent=args.eps_percent)

    xq, yq = fp.to_q824(x), fp.to_q824(y)
    w0 = slice(0, args.nraw)
    Vx0, Vy0 = embed_pair(x[w0], y[w0], px, py)
    e2x = fp.eps2_to_q824(resolve_eps(Vx0, px))
    e2y = fp.eps2_to_q824(resolve_eps(Vy0, py))

    nx = args.nraw - (args.m - 1) * args.tau
    n = nx
    lines = []
    for k in range(args.nwin):
        sl = slice(k * args.nraw, (k + 1) * args.nraw)
        Vqx, Vqy = embed_pair(xq[sl], yq[sl], px, py)
        Vqx, Vqy = Vqx.astype(np.int64), Vqy.astype(np.int64)
        R = fp.recurrence_flags_q824(Vqx, e2x) & fp.recurrence_flags_q824(Vqy, e2y)
        assert R.shape[0] == n
        c = rtl_counters(R)
        det = " ".join(f"{int(b)} {v}" for b, v in sorted(c["det_hist"].items(), key=lambda kv: int(kv[0])))
        lam = " ".join(f"{int(b)} {v}" for b, v in sorted(c["lam_hist"].items(), key=lambda kv: int(kv[0])))
        lines += [
            "set wexp(%d) {%d %d %d %d %d %d %d}" % (k, c["rr_count"], c["det_points"], c["det_lines"], c["l_max"],
                                                    c["lam_points"], c["lam_lines"], c["v_max"]),
            "set wdet(%d) {%s}" % (k, det), "set wlam(%d) {%s}" % (k, lam),
        ]
        print(f"window {k}: rr {c['rr_count']} det_lines {c['det_lines']} l_max {c['l_max']} lam_lines {c['lam_lines']} v_max {c['v_max']}")

    head = [
        f"set case(name) {args.name}", f"set case(ns) {args.nraw}", f"set case(n) {n}", "set case(dual) 1",
        f"set case(mx) {args.m}", f"set case(tx) {args.tau}", f"set case(my) {args.m}", f"set case(ty) {args.tau}",
        f"set case(e2x) {e2x}", f"set case(e2y) {e2y}", "set case(base_x) 0", "set case(base_y) 0",
        f"set case(nx) {nx}", f"set case(ny) {nx}", f"set case(nwin) {args.nwin}",
        "set case(expect) {%s}" % lines[0].split("{")[1].rstrip("}"),
        "set case(det_hist) {}", "set case(lam_hist) {}", "set case(x) {}", "set case(y) {}",
    ]
    (P3 / "build" / "hwcase").mkdir(parents=True, exist_ok=True)
    (P3 / "build" / "hwcase" / f"{args.name}.tcl").write_text("\n".join(head + lines) + "\n")
    buf = bytearray()
    for xv, yv in zip(xq, yq):
        buf += struct.pack("<II", int(xv) & 0xFFFFFFFF, int(yv) & 0xFFFFFFFF)
    (P3 / "build" / "rtcase").mkdir(parents=True, exist_ok=True)
    (P3 / "build" / "rtcase" / f"{args.name}.bin").write_bytes(bytes(buf))
    print(f"wrote {args.name}: {args.nwin} windows x {args.nraw} samples, n_vectors {n}, eps2 x/y 0x{e2x:08X} 0x{e2y:08X}, "
          f"{len(buf)} bytes of OCM image (SYNTHETIC Lorenz x and z)")


if __name__ == "__main__":
    main()
