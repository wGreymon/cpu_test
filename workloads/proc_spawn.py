#!/usr/bin/env python3
"""OS-03 定制项：连续创建 N 个短进程（/bin/true），逐个计时，输出 P50/P95/P99。
注意：结果包含 Python subprocess 调用开销，仅用于平台间横向对比，不代表纯 fork+exec 延迟
（纯值以 lmbench lat_proc 为准）。"""
import subprocess, sys, time

n = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
ts = []
for _ in range(n):
    t0 = time.perf_counter_ns()
    subprocess.run(["/bin/true"], check=True)
    ts.append((time.perf_counter_ns() - t0) / 1000.0)  # µs

ts.sort()
p = lambda q: ts[min(int(q * len(ts)), len(ts) - 1)]
total_s = sum(ts) / 1e6
print(f"spawn_p50_us: {p(0.50):.1f}")
print(f"spawn_p95_us: {p(0.95):.1f}")
print(f"spawn_p99_us: {p(0.99):.1f}")
print(f"spawn_rate_per_s: {n / total_s:.1f}")
