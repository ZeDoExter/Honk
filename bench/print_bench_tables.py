#!/usr/bin/env python3
"""Print compact Phase 3 round tables for the report (repo root cwd)."""
import json
import statistics

d = json.load(open("bench/bench_compete_results.json"))
for w in ("W1", "W2", "W3", "W4"):
    print(f"== {w} rps R1..R5 ==")
    for k, runs in d["runs"][w].items():
        vals = " ".join(f"{r['req_per_sec']:.0f}" for r in runs)
        print(f"  {k:10s}: {vals}")
    print(f"== {w} user_us R1..R5 ==")
    for k, runs in d["runs"][w].items():
        vals = " ".join(f"{r['user_us_per_req']:.3f}" for r in runs)
        print(f"  {k:10s}: {vals}")
    print(f"== {w} summaries ==")
    for k, s in d["summaries"][w].items():
        print(f"  {k:10s}: rps_med={s['rps_median']} min={s['rps_min']} max={s['rps_max']} "
              f"cpu={s['cpu_us_per_req_median']} usr={s['user_us_per_req_median']} "
              f"sys={s['sys_us_per_req_median']} srv={s['server_cpu_pct_median']} "
              f"wrk={s['wrk_cpu_pct_median']}")
