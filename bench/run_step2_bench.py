#!/usr/bin/env python3
"""
Phase 2 performance + memory baseline (Release builds ONLY, indicative WSL2).

A. curl -i 115-byte equivalence: bare-C control vs server_phase2 /plaintext.
B. 7-round interleaved GET /plaintext (C, Phase2, ...) with pidstat + CPU/req.
C. JSON baselines: GET /json (4 rounds) + POST /api/typed via wrk Lua (4 rounds).
D. RSS check: idle / 64 / 1024 conns + after sustained JSON traffic.
"""

import json
import os
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_step1b_interleaved import (  # noqa: E402
    BUN_BIN, CLK_TCK, PIDSTAT_BIN, WRK_BIN, parse_pidstat_averages,
    parse_wrk_output, read_proc_cpu_ticks, summarize_runs, wait_for_port,
)


def run_one_url(server_pid, url, round_num, label, script=None):
    u0, s0 = read_proc_cpu_ticks(server_pid)
    cmd = ["taskset", "-c", "4,6", WRK_BIN, "-t2", "-c64", "-d10s", "--latency"]
    if script:
        cmd += ["-s", script]
    cmd.append(url)
    wrk_proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
    time.sleep(0.5)
    pidstat_proc = subprocess.Popen(
        [PIDSTAT_BIN, "-u", "-p", f"{server_pid},{wrk_proc.pid}", "1", "8"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    wrk_out, wrk_err = wrk_proc.communicate()
    u1, s1 = read_proc_cpu_ticks(server_pid)
    pidstat_out, _ = pidstat_proc.communicate()

    w = parse_wrk_output(wrk_out)
    p = parse_pidstat_averages(pidstat_out, server_pid, wrk_proc.pid)
    user_sec = (u1 - u0) / CLK_TCK
    sys_sec = (s1 - s0) / CLK_TCK
    total_cpu_sec = user_sec + sys_sec
    reqs = max(w["total_requests"], 1)
    rec = {
        "round": round_num,
        "label": label,
        "url": url,
        "req_per_sec": w["req_per_sec"],
        "total_requests": w["total_requests"],
        "p99_latency": w["p99_latency"],
        "server_cpu_pct": p["server_cpu_pct"],
        "server_usr_pct": p["server_usr_pct"],
        "server_sys_pct": p["server_sys_pct"],
        "wrk_cpu_pct": p["wrk_cpu_pct"],
        "server_user_sec": round(user_sec, 4),
        "server_sys_sec": round(sys_sec, 4),
        "server_total_cpu_sec": round(total_cpu_sec, 4),
        "cpu_us_per_req": round((total_cpu_sec * 1e6) / reqs, 3),
        "user_us_per_req": round((user_sec * 1e6) / reqs, 3),
        "sys_us_per_req": round((sys_sec * 1e6) / reqs, 3),
        "status_flag": ("SATURATED-BY-CLIENT (<85% srv CPU)"
                        if p["server_cpu_pct"] < 85.0 else "SERVER-CORE-BUSY"),
    }
    rec["saturated_by_client"] = rec["status_flag"].startswith("SATURATED")
    print(f"  [Round {round_num}] {label:22s}: {rec['req_per_sec']:10.2f} req/s | "
          f"CPU/req: {rec['cpu_us_per_req']:5.3f} us (usr {rec['user_us_per_req']:5.3f}, "
          f"sys {rec['sys_us_per_req']:5.3f}) | SrvCPU: {rec['server_cpu_pct']:5.1f}% | "
          f"wrkCPU: {rec['wrk_cpu_pct']:5.1f}% | p99: {rec['p99_latency']:>7s} | {rec['status_flag']}")
    if w["total_requests"] == 0:
        print(f"      wrk stderr: {wrk_err[-500:]}")
    return rec


def curl_bytes(port, target="/plaintext"):
    out = subprocess.run(["curl", "-s", "-i", f"http://127.0.0.1:{port}{target}"],
                         capture_output=True, timeout=5).stdout
    return out


def check_curl_equivalence(port_c, port_p2):
    proc_c = subprocess.Popen(["taskset", "-c", "0", "./bench/c_control/server_c", str(port_c)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    proc_g = subprocess.Popen(["taskset", "-c", "0", "./src/server_phase2", str(port_p2),
                               "30000", "10000", "1"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait_for_port(port_c)
        wait_for_port(port_p2)
        for attempt in range(3):
            b_c = curl_bytes(port_c)
            b_g = curl_bytes(port_p2)
            if b_c == b_g:
                break
            time.sleep(1.1 - time.time() % 1 + 0.05)
        with open("bench/curl_c_control_p2.txt", "wb") as f:
            f.write(b_c)
        with open("bench/curl_phase2.txt", "wb") as f:
            f.write(b_g)
        print(f"  C control bytes: {len(b_c)}, Phase2 bytes: {len(b_g)}")
        assert len(b_c) == 115 and len(b_g) == 115, (len(b_c), len(b_g))
        assert b_c == b_g, f"byte mismatch:\n{b_c!r}\n{b_g!r}"
        print("  [PASS] curl -i 115-byte equivalence")
    finally:
        proc_c.terminate()
        proc_g.terminate()
        proc_c.wait()
        proc_g.wait()


def read_proc_mem(pid):
    rss = hwm = 0
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith("VmRSS:"):
                rss = int(line.split()[1])
            elif line.startswith("VmHWM:"):
                hwm = int(line.split()[1])
    return {"VmRSS_kB": rss, "VmHWM_kB": hwm}


def measure_rss(port):
    proc = subprocess.Popen(["./src/server_phase2", str(port), "30000", "10000", "1"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        proc.stdout.readline()
        wait_for_port(port)
        out = {"idle": read_proc_mem(proc.pid)}
        conns = []
        for _ in range(64):
            s = socket.create_connection(("127.0.0.1", port), timeout=3.0)
            s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n")
            s.recv(256)
            conns.append(s)
        time.sleep(0.3)
        out["conns_64"] = read_proc_mem(proc.pid)
        for _ in range(64, 1024):
            s = socket.create_connection(("127.0.0.1", port), timeout=3.0)
            s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n")
            s.recv(256)
            conns.append(s)
        time.sleep(0.5)
        out["conns_1024"] = read_proc_mem(proc.pid)
        # Sustained JSON traffic, then re-measure with conns still open.
        typed = b'{"name":"soak","age":1,"tags":["a","b"],"address":{"city":"c","zip":1}}'
        for _ in range(2000):
            s = socket.create_connection(("127.0.0.1", port), timeout=3.0)
            s.sendall(b"POST /api/typed HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n"
                      b"Connection: close\r\n\r\n" % len(typed) + typed)
            while s.recv(4096):
                pass
            s.close()
        for _ in range(2000):
            s = socket.create_connection(("127.0.0.1", port), timeout=3.0)
            s.sendall(b"GET /json HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            while s.recv(4096):
                pass
            s.close()
        time.sleep(0.3)
        out["conns_1024_after_json"] = read_proc_mem(proc.pid)
        for s in conns:
            s.close()
        return out
    finally:
        proc.terminate()
        proc.wait()


def main():
    port_c = 18390
    port_p2 = 18391
    port_j = 18392

    print("=== A. curl -i byte-equivalence (C control vs Phase 2) ===")
    check_curl_equivalence(port_c, port_p2)

    print("\n=== B. 7-round interleaved GET /plaintext (Round 1 = warmup) ===")
    proc_c = subprocess.Popen(["taskset", "-c", "0", "./bench/c_control/server_c", str(port_c)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    proc_g = subprocess.Popen(["taskset", "-c", "0", "./src/server_phase2", str(port_p2),
                               "30000", "10000", "1"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    c_runs, g_runs = [], []
    try:
        wait_for_port(port_c)
        wait_for_port(port_p2)
        for r in range(1, 8):
            c_runs.append(run_one_url(proc_c.pid, f"http://127.0.0.1:{port_c}/plaintext",
                                      r, "Bare-C Control"))
            time.sleep(0.5)
            g_runs.append(run_one_url(proc_g.pid, f"http://127.0.0.1:{port_p2}/plaintext",
                                      r, "Honk Phase 2"))
            time.sleep(0.5)
    finally:
        proc_c.terminate()
        proc_g.terminate()
        proc_c.wait()
        proc_g.wait()

    print("\n=== C1. GET /json baseline (Round 1 = warmup) ===")
    proc_j = subprocess.Popen(["taskset", "-c", "0", "./src/server_phase2", str(port_j),
                               "30000", "10000", "1"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    json_runs, post_runs = [], []
    try:
        wait_for_port(port_j)
        for r in range(1, 5):
            json_runs.append(run_one_url(proc_j.pid, f"http://127.0.0.1:{port_j}/json",
                                         r, "Phase2 GET /json"))
            time.sleep(0.5)
        print("\n=== C2. POST /api/typed baseline via wrk Lua (Round 1 = warmup) ===")
        for r in range(1, 5):
            post_runs.append(run_one_url(proc_j.pid, f"http://127.0.0.1:{port_j}/api/typed",
                                         r, "Phase2 POST typed",
                                         script="bench/post_typed.lua"))
            time.sleep(0.5)
    finally:
        proc_j.terminate()
        proc_j.wait()

    print("\n=== D. RSS check (idle / 64 / 1024 / after-JSON) ===")
    rss = measure_rss(18393)
    print(" ", json.dumps(rss, indent=2))

    c_sum = summarize_runs(c_runs[1:])
    g_sum = summarize_runs(g_runs[1:])
    j_sum = summarize_runs(json_runs[1:])
    p_sum = summarize_runs(post_runs[1:])
    with open("bench/step2_bench_results.json", "w") as f:
        json.dump({"c_runs_all": c_runs, "phase2_runs_all": g_runs,
                   "json_get_runs_all": json_runs, "json_post_runs_all": post_runs,
                   "c_summary_r2_r7": c_sum, "phase2_summary_r2_r7": g_sum,
                   "json_get_summary_r2_r4": j_sum, "json_post_summary_r2_r4": p_sum,
                   "rss": rss}, f, indent=2)

    print("\n=== Summary (indicative WSL2) ===")
    for name, s in (("Bare-C", c_sum), ("Phase2 /plaintext", g_sum),
                    ("Phase2 GET /json", j_sum), ("Phase2 POST typed", p_sum)):
        print(f"{name:18s}: median {s['rps_median']:.2f} req/s "
              f"(min {s['rps_min']:.2f}, max {s['rps_max']:.2f}) | "
              f"CPU/req {s['cpu_us_per_req_median']:.3f} us "
              f"(usr {s['user_us_per_req_median']:.3f}, sys {s['sys_us_per_req_median']:.3f}) | "
              f"SrvCPU {s['server_cpu_pct_median']}% | wrkCPU {s['wrk_cpu_pct_median']}%")


if __name__ == "__main__":
    main()
