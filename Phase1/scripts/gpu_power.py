"""GPU card power while the all-GPU pipeline (coupled logistic maps, N=4096, m=5, tau=3, eps 50 %) runs back to back.
Samples nvidia-smi power.draw every 100 ms: 10 s idle, then 20 s of continuous frames. Reports mean idle and loaded power
(whole graphics card) and energy per frame = loaded power x mean frame time. nvidia-smi power.draw is averaged over about 1 s.
Writes results/gpu_power.md."""
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


def frame():
    xu, yu = to_unit_interval(x), to_unit_interval(y)
    Vx, Vy = embed_pair(xu, yu, px, py, xp=cp)
    rqa_metrics_gpu(joint_recurrence_gpu(Vx, Vy, ex, ey))


samples, stop = [], threading.Event()


def sampler():
    pr = subprocess.Popen(["nvidia-smi", "--query-gpu=power.draw", "--format=csv,noheader,nounits", "-lms", "100"],
                          stdout=subprocess.PIPE, text=True)
    for line in pr.stdout:
        samples.append((time.time(), float(line.strip())))
        if stop.is_set():
            break
    pr.kill()


for _ in range(5):
    frame()
t = threading.Thread(target=sampler, daemon=True)
t.start()
t0 = time.time()
time.sleep(10)
t_load0 = time.time()
n = 0
while time.time() - t_load0 < 20:
    frame(); n += 1
cp.cuda.Stream.null.synchronize()
t_load1 = time.time()
stop.set(); time.sleep(0.3)
s = np.array(samples)
idle = s[(s[:, 0] > t0 + 2) & (s[:, 0] < t_load0), 1].mean()
load = s[(s[:, 0] > t_load0 + 3) & (s[:, 0] < t_load1), 1].mean()
ft = (t_load1 - t_load0) / n
txt = [f"# GPU card power, all-GPU pipeline, N={N}", "",
       f"{n} frames back to back in {t_load1 - t_load0:.1f} s: {ft * 1000:.1f} ms per frame including host-side work. "
       f"Mean card power idle {idle:.1f} W, under load {load:.1f} W (nvidia-smi, 100 ms samples, first 3 s of load excluded).",
       f"Energy per frame at the loaded power: {load * ft:.2f} J (loaded minus idle: {(load - idle) * ft:.2f} J)."]
Path(__file__).resolve().parents[1].joinpath("results", "gpu_power.md").write_text("\n".join(txt) + "\n")
print("\n".join(txt))
