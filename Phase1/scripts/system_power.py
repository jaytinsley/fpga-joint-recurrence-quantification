"""CPU package power (Intel RAPL through the Windows "Energy Meter" counters) and GPU card power (nvidia-smi) while the N=4096
coupled-logistic JRP pipeline runs on (a) the CPU (NumPy, one thread as in the benchmark) and (b) the GPU with on-device extraction.
Phases: 10 s idle, 20 s NumPy frames back to back, 10 s idle, 20 s GPU frames back to back. Samples about once per second (RAPL) and every
100 ms (nvidia-smi); the first 3 s of each load phase are excluded. RAPL package power covers the CPU cores, cache and uncore, not DRAM
or the rest of the PC. Energy per frame = mean power x mean frame time. Writes results/system_power.md."""
import os

os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"
import subprocess
import threading
import time
from pathlib import Path

import numpy as np
import cupy as cp

from jrp import bench
from jrp.jrp import ChannelParams, embed_pair
from jrp.rqa_gpu import joint_recurrence_gpu, rqa_metrics_gpu
from jrp.signals import gen_coupled_logistic, to_unit_interval

N, M, TAU = 4096, 5, 3
x, y = gen_coupled_logistic(N, 0.1)
p = ChannelParams(M, TAU, eps_percent=50.0)
ex, ey, _ = bench.resolve_eps_absolute(x, y, p, p, 1024, "cupy")
px, py = ChannelParams(M, TAU, eps=ex), ChannelParams(M, TAU, eps=ey)


def frame_gpu():
    xu, yu = to_unit_interval(x), to_unit_interval(y)
    Vx, Vy = embed_pair(xu, yu, px, py, xp=cp)
    rqa_metrics_gpu(joint_recurrence_gpu(Vx, Vy, ex, ey))


def frame_cpu():
    bench.run_once(x, y, px, py, ex, ey, backend="numpy")


rapl, gpu, stop = [], [], threading.Event()


def read(cmd, store, scale):
    pr = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True)
    for line in pr.stdout:
        if stop.is_set():
            break
        f = line.strip().strip('"').split('","')
        try:
            store.append((time.time(), float(f[-1]) * scale))
        except ValueError:
            pass
    pr.kill()


for _ in range(3):
    frame_cpu(); frame_gpu()
threading.Thread(target=read, daemon=True, args=(["typeperf", r"\Energy Meter(RAPL_Package0_PKG)\Power", "-si", "1", "-sc", "120"], rapl, 1e-3)).start()
threading.Thread(target=read, daemon=True, args=(["nvidia-smi", "--query-gpu=power.draw", "--format=csv,noheader,nounits", "-lms", "100"], gpu, 1.0)).start()
time.sleep(10); t_idle0 = time.time() - 8; t_idle1 = time.time()


def run(fn, secs):
    t0, n = time.time(), 0
    while time.time() - t0 < secs:
        fn(); n += 1
    return t0, time.time(), n


c0, c1, cn = run(frame_cpu, 20)
time.sleep(10)
i2 = (time.time() - 7, time.time())
g0, g1, gn = run(frame_gpu, 20)
cp.cuda.Stream.null.synchronize(); g1 = time.time()
stop.set(); time.sleep(1.5)


def mean(store, a, b):
    v = [w for t, w in store if a <= t <= b]
    return float(np.mean(v)), len(v)


idle_cpu = mean(rapl, t_idle0, t_idle1)[0]
idle_cpu2 = mean(rapl, *i2)[0]
cpu_load = mean(rapl, c0 + 3, c1)
cpu_ft = (c1 - c0) / cn
g_cpu = mean(rapl, g0 + 3, g1)
g_gpu = mean(gpu, g0 + 3, g1)
gpu_idle = mean(gpu, t_idle0, t_idle1)[0]
g_ft = (g1 - g0) / gn
txt = ["# CPU and GPU power, N=4096 coupled-logistic JRP pipeline", "",
       f"CPU package power (RAPL): idle {idle_cpu:.1f} W and {idle_cpu2:.1f} W (before and between loads); NumPy pipeline {cpu_load[0]:.1f} W ({cpu_load[1]} samples), "
       f"{cpu_ft * 1000:.0f} ms per frame, {cn} frames, energy {cpu_load[0] * cpu_ft:.1f} J per frame (above idle {(cpu_load[0] - idle_cpu) * cpu_ft:.1f} J).",
       f"All-GPU pipeline: card {g_gpu[0]:.1f} W (idle {gpu_idle:.1f} W) plus CPU package {g_cpu[0]:.1f} W, {g_ft * 1000:.1f} ms per frame, {gn} frames; "
       f"energy per frame {g_gpu[0] * g_ft:.2f} J card only, {(g_gpu[0] + g_cpu[0]) * g_ft:.2f} J card plus CPU package."]
Path(__file__).resolve().parents[1].joinpath("results", "system_power.md").write_text("\n".join(txt) + "\n")
print("\n".join(txt))
