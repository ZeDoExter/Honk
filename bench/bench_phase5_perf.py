#!/usr/bin/env python3
"""
Phase 5 perf baseline (Release, single-core pinned, WSL2 indicative).

- W1 non-regression: Bare-C vs Honk bench mode, GET /plaintext, 5 rounds.
- Static: Honk sendfile GET /asset256k.bin (256 KiB), 5 rounds.
- SQLite: Honk prepared point lookup GET /db?id=42 (1000 seeded rows), 5 rounds.
- VmRSS after load + binary sizes (quickstart vs fullstack, ldd sqlite check).
"""

import json
import os
import socket
import sqlite3
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_bench_transport import summarize_runs  # noqa: E402
import run_bench_compete as C  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def wait_ready(port, timeout=30.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1.0) as s:
                s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                if s.recv(15).startswith(b"HTTP/1.1"):
                    return
        except OSError:
            pass
        time.sleep(0.1)
    raise RuntimeError(f"port {port} not ready")


def bench_5rounds(pid, url, label, script=None):
    C.run_wrk(pid, url, script, 3, "warmup")
    runs = []
    for r in range(1, 6):
        rec = C.run_wrk(pid, url, script, 5, label)
        rec["round"] = r
        runs.append(rec)
        print(f"  [{label} R{r}] {rec['req_per_sec']:10.2f} req/s | "
              f"CPU {rec['cpu_us_per_req']:6.3f} (u{rec['user_us_per_req']:6.3f}/"
              f"s{rec['sys_us_per_req']:6.3f}) | srv {rec['server_cpu_pct']:5.1f}% | "
              f"wrk {rec['wrk_cpu_pct']:5.1f}% | {rec['status_flag']}", flush=True)
    return runs


def main():
    out = {}
    # --- fixtures: 256 KiB static asset + seeded sqlite db (native tmp) ---
    import tempfile
    work = tempfile.mkdtemp(prefix="p5perf_")
    asset = os.path.join(work, "asset256k.bin")
    with open(asset, "wb") as f:
        f.write(bytes((i * 2654435761) % 256 for i in range(256 * 1024)))
    dbpath = os.path.join(work, "bench.db")
    con = sqlite3.connect(dbpath)
    con.execute("CREATE TABLE kv(id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER NOT NULL)")
    con.executemany("INSERT INTO kv(name, age) VALUES (?, ?)",
                    [(f"user-{i:04d}-with-a-longer-name-field", i % 97) for i in range(1000)])
    con.commit()
    con.close()

    procs = {}
    try:
        procs["c"] = subprocess.Popen(
            ["taskset", "-c", "0", "./bench/c_control/server_c", "18631"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT)
        procs["honk"] = subprocess.Popen(
            ["taskset", "-c", "0", "./src/server", "18632",
             "30000", "10000", "1", "1"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT)
        procs["static"] = subprocess.Popen(
            ["taskset", "-c", "0", "./test/phase5_app", "18633", work, "1",
             os.path.join(work, "static.db")],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT)
        procs["db"] = subprocess.Popen(
            ["taskset", "-c", "0", "./test/phase5_app", "18634", work, "1", dbpath],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT)
        for p in (18631, 18632, 18633, 18634):
            wait_ready(p)

        print("=== W1 plaintext: Bare-C vs Honk (5 interleaved rounds) ===")
        runs_c, runs_h = [], []
        for r in range(1, 6):
            if r == 1:
                C.run_wrk(procs["c"].pid, "http://127.0.0.1:18631/plaintext",
                          None, 3, "wu")
                C.run_wrk(procs["honk"].pid, "http://127.0.0.1:18632/plaintext",
                          None, 3, "wu")
            rc = C.run_wrk(procs["c"].pid, "http://127.0.0.1:18631/plaintext",
                           None, 5, "Bare-C")
            rc["round"] = r
            runs_c.append(rc)
            rh = C.run_wrk(procs["honk"].pid, "http://127.0.0.1:18632/plaintext",
                           None, 5, "Honk")
            rh["round"] = r
            runs_h.append(rh)
            print(f"  [R{r}] C {rc['req_per_sec']:10.2f} (u{rc['user_us_per_req']:.3f}) | "
                  f"Honk {rh['req_per_sec']:10.2f} (u{rh['user_us_per_req']:.3f})",
                  flush=True)
        out["w1_c"] = summarize_runs(runs_c)
        out["w1_honk"] = summarize_runs(runs_h)

        print("=== Static sendfile: GET /asset256k.bin (5 rounds) ===")
        runs_s = bench_5rounds(procs["static"].pid,
                               "http://127.0.0.1:18633/asset256k.bin", "static")
        out["static"] = summarize_runs(runs_s)

        print("=== SQLite point lookup: GET /db?id=42 (5 rounds) ===")
        runs_d = bench_5rounds(procs["db"].pid,
                               "http://127.0.0.1:18634/db?id=42", "sqlite")
        out["sqlite"] = summarize_runs(runs_d)

        print("=== RSS after load ===")
        rss = {}
        for key, port in (("honk", 18632), ("static", 18633), ("db", 18634)):
            pid = procs[{"honk": "honk", "static": "static", "db": "db"}[key]].pid
            with open(f"/proc/{pid}/status") as f:
                txt = f.read()
            import re
            r = int(re.search(r"VmRSS:\s+(\d+)", txt).group(1))
            h = int(re.search(r"VmHWM:\s+(\d+)", txt).group(1))
            rss[key] = {"VmRSS_kB": r, "VmHWM_kB": h}
            print(f"  {key}: RSS {r} kB, HWM {h} kB")
        out["rss"] = rss
    finally:
        for p in procs.values():
            p.terminate()
        for p in procs.values():
            p.wait()

    print("=== Binary sizes ===")
    sizes = {}
    for key, path in (("quickstart", "examples/quickstart/app"),
                      ("server", "src/server"),
                      ("fullstack", "examples/fullstack_todo/app")):
        full = os.path.join(ROOT, path)
        kb = os.path.getsize(full) / 1024
        ldd = subprocess.run(["ldd", full], capture_output=True, text=True).stdout
        has_sqlite = "libsqlite3" in ldd
        sizes[key] = {"KiB": round(kb, 1), "libsqlite3": has_sqlite}
        print(f"  {key}: {kb:.1f} KiB, libsqlite3 linked: {has_sqlite}")
    out["sizes"] = sizes

    with open("bench/bench_phase5_perf.json", "w") as f:
        json.dump(out, f, indent=2)
    print("\n=== Medians ===")
    for k in ("w1_c", "w1_honk", "static", "sqlite"):
        s = out[k]
        print(f"  {k:8s}: {s['rps_median']:.2f} req/s "
              f"(min {s['rps_min']:.2f}, max {s['rps_max']:.2f}) | "
              f"CPU {s['cpu_us_per_req_median']:.3f} "
              f"(u{s['user_us_per_req_median']:.3f}/s{s['sys_us_per_req_median']:.3f})")


if __name__ == "__main__":
    main()
