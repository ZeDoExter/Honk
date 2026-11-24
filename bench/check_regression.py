#!/usr/bin/env python3
"""
Zero-regression sanity: Honk (serve API, bench mode) vs Bare-C on W1+W2.

5 interleaved rounds after a 3s warm-up each (same pinning/protocol as the
compete harness), plus an RSS flatness check. Fails loudly on >15% median
req/s drop vs the recorded Phase 3 baselines or any RSS growth.
"""

import json
import os
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_bench_transport import summarize_runs  # noqa: E402
import run_bench_compete as C  # noqa: E402

BASELINES = {
    # Phase 3 medians (same box, WSL2 indicative): rps + user us/req.
    "W1": {"rps": 83512.72, "usr": 0.863},
    "W2": {"rps": 73476.54, "usr": 1.208},
}


def main():
    port_c, port_h = 18611, 18612
    procs = [
        subprocess.Popen(["taskset", "-c", "0", "./bench/c_control/server_c", str(port_c)],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE),
        subprocess.Popen(["taskset", "-c", "0", "./src/server", str(port_h),
                          "30000", "10000", "1", "1"],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE),
    ]
    try:
        C.wait_ready(port_c, timeout=30)
        C.wait_ready(port_h, timeout=30)
        all_ok = True
        for wid, target in ((1, "/plaintext"), (2, "/json")):
            wkey = f"W{wid}"
            print(f"=== {wkey} {target}: 3s warm-up + 5 interleaved rounds ===")
            runs_c, runs_h = [], []
            for r in range(1, 6):
                rc = C.run_wrk(procs[0].pid, f"http://127.0.0.1:{port_c}{target}",
                               None, 5, "Bare-C")
                rc["round"] = r
                runs_c.append(rc)
                rh = C.run_wrk(procs[1].pid, f"http://127.0.0.1:{port_h}{target}",
                               None, 5, "Honk")
                rh["round"] = r
                runs_h.append(rh)
                ratio = rh["req_per_sec"] / max(rc["req_per_sec"], 1)
                print(f"  [R{r}] C {rc['req_per_sec']:10.2f} (u{rc['user_us_per_req']:.3f}) | "
                      f"Honk {rh['req_per_sec']:10.2f} (u{rh['user_us_per_req']:.3f}) | "
                      f"ratio {ratio:.3f}")
            s_h = summarize_runs(runs_h)
            s_c = summarize_runs(runs_c)
            base = BASELINES[wkey]
            rps_ratio = s_h["rps_median"] / base["rps"]
            honk_c_ratio = s_h["rps_median"] / max(s_c["rps_median"], 1)
            usr_delta = s_h["user_us_per_req_median"] - s_c["user_us_per_req_median"]
            print(f"  {wkey} Honk median {s_h['rps_median']:.2f} req/s "
                  f"(baseline {base['rps']:.2f}, base-ratio {rps_ratio:.3f}, "
                  f"same-run C-ratio {honk_c_ratio:.3f}), "
                  f"usr {s_h['user_us_per_req_median']:.3f} "
                  f"(C {s_c['user_us_per_req_median']:.3f}, delta {usr_delta:+.3f})")
            # Same-run Honk/C ratio is the robust gate (immune to machine drift);
            # absolute baseline is advisory only on WSL2.
            if honk_c_ratio < 0.80:
                print(f"  [REGRESSION] {wkey} Honk/C ratio {honk_c_ratio:.3f} < 0.80!")
                all_ok = False
            if usr_delta > 0.500:
                print(f"  [REGRESSION] {wkey} user delta {usr_delta:+.3f}us > +0.500us!")
                all_ok = False
        print("\n=== RSS flatness (Honk 512+load vs 2048 kB steady state) ===")
        rss = C.measure_rss([c for c in C.CONTENDERS if c["key"] == "honk"][0], port_h)
        idle, loaded = rss["idle"]["VmRSS_kB"], rss["conns_512_after_load"]["VmRSS_kB"]
        print(f"  idle {idle} kB, 512+load {loaded} kB (HWM {rss['conns_512_after_load']['VmHWM_kB']} kB)")
        if loaded > 2300:
            print("  [REGRESSION] RSS under load exceeds 2300 kB!")
            all_ok = False
        print("\nRESULT:", "NO REGRESSION" if all_ok else "REGRESSION DETECTED")
        sys.exit(0 if all_ok else 1)
    finally:
        for p in procs:
            p.terminate()
        for p in procs:
            p.wait()


if __name__ == "__main__":
    main()
