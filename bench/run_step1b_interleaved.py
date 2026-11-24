#!/usr/bin/env python3
"""
Requirement G: Fixed Measurement Protocol for Step 1b.
  - Interleaved 7 rounds (C, Goose, C, Goose, ...), discard Round 1, report median and min/max across Rounds 2..7.
  - Record server CPU% and wrk CPU% during each run via `pidstat -u -p <pid> 1`.
  - Mark any run where server core is not near 100% busy (< 85% CPU) as SATURATED-BY-CLIENT.
  - Report CPU time per request ((user + sys) CPU seconds from /proc/<pid>/stat divided by requests served).
  - Run a 5-line Bun.serve hello-world with the exact same wrk settings and CPU pinning as a
    "harness sanity check, not a comparison".
"""

import json
import os
import re
import socket
import statistics
import subprocess
import time

HOME = os.path.expanduser("~")
WRK_BIN = os.path.join(HOME, ".local", "bin", "wrk")
PIDSTAT_BIN = os.path.join(HOME, ".local", "bin", "pidstat")
BUN_BIN = os.path.join(HOME, ".local", "bin", "bun")
CLK_TCK = os.sysconf(os.sysconf_names["SC_CLK_TCK"])


def wait_for_port(port: int, timeout: float = 5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5) as s:
                s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                if b"200 OK" in s.recv(1024):
                    return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError(f"Port {port} did not become ready")


def read_proc_cpu_ticks(pid: int) -> tuple:
    with open(f"/proc/{pid}/stat", "r") as f:
        s = f.read()
    fields = s[s.rfind(")") + 2 :].split()
    utime = int(fields[11])
    stime = int(fields[12])
    return utime, stime


def parse_wrk_output(out: str) -> dict:
    m_rps = re.search(r"Requests/sec:\s+([0-9.]+)", out)
    m_reqs = re.search(r"(\d+)\s+requests in\s+([0-9.]+)s", out)
    m_p99 = re.search(r"99%\s+([0-9.]+)(us|ms|s)", out)

    rps = float(m_rps.group(1)) if m_rps else 0.0
    total_reqs = int(m_reqs.group(1)) if m_reqs else 0
    duration_s = float(m_reqs.group(2)) if m_reqs else 10.0
    p99_str = f"{m_p99.group(1)}{m_p99.group(2)}" if m_p99 else "N/A"
    return {
        "req_per_sec": rps,
        "total_requests": total_reqs,
        "duration_s": duration_s,
        "p99_latency": p99_str,
    }


def parse_pidstat_averages(out: str, server_pid: int, wrk_pid: int) -> dict:
    res = {
        "server_usr_pct": 0.0,
        "server_sys_pct": 0.0,
        "server_cpu_pct": 0.0,
        "wrk_usr_pct": 0.0,
        "wrk_sys_pct": 0.0,
        "wrk_cpu_pct": 0.0,
    }
    for line in out.splitlines():
        if not line.startswith("Average:"):
            continue
        parts = line.split()
        # Format: Average: UID PID %usr %system %guest %wait %CPU CPU Command
        if len(parts) < 8:
            continue
        try:
            pid = int(parts[2])
            usr = float(parts[3])
            sys_p = float(parts[4])
            cpu = float(parts[7])
        except ValueError:
            continue
        if pid == server_pid:
            res["server_usr_pct"] = usr
            res["server_sys_pct"] = sys_p
            res["server_cpu_pct"] = cpu
        elif pid == wrk_pid:
            res["wrk_usr_pct"] = usr
            res["wrk_sys_pct"] = sys_p
            res["wrk_cpu_pct"] = cpu
    return res


def run_one_wrk(server_pid: int, port: int, round_num: int, label: str) -> dict:
    url = f"http://127.0.0.1:{port}/plaintext"
    u0, s0 = read_proc_cpu_ticks(server_pid)

    wrk_proc = subprocess.Popen(
        ["taskset", "-c", "4,6", WRK_BIN, "-t2", "-c64", "-d10s", "--latency", url],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    time.sleep(0.5)
    # Note: wrk spawns child process via wrapper script ~/.local/bin/wrk -> find actual wrk.bin pid if wrapped
    # Actually ~/.local/bin/wrk uses `exec`, so wrk_proc.pid IS wrk.bin!
    pidstat_proc = subprocess.Popen(
        [PIDSTAT_BIN, "-u", "-p", f"{server_pid},{wrk_proc.pid}", "1", "8"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    wrk_out, _ = wrk_proc.communicate()
    u1, s1 = read_proc_cpu_ticks(server_pid)
    pidstat_out, _ = pidstat_proc.communicate()

    w = parse_wrk_output(wrk_out)
    p = parse_pidstat_averages(pidstat_out, server_pid, wrk_proc.pid)

    user_sec = (u1 - u0) / CLK_TCK
    sys_sec = (s1 - s0) / CLK_TCK
    total_cpu_sec = user_sec + sys_sec
    reqs = max(w["total_requests"], 1)
    cpu_us_per_req = (total_cpu_sec * 1e6) / reqs
    user_us_per_req = (user_sec * 1e6) / reqs
    sys_us_per_req = (sys_sec * 1e6) / reqs

    saturated_by_client = p["server_cpu_pct"] < 85.0
    status_flag = "SATURATED-BY-CLIENT (<85% srv CPU)" if saturated_by_client else "SERVER-CORE-BUSY"

    rec = {
        "round": round_num,
        "label": label,
        "req_per_sec": w["req_per_sec"],
        "total_requests": w["total_requests"],
        "p99_latency": w["p99_latency"],
        "server_cpu_pct": p["server_cpu_pct"],
        "server_usr_pct": p["server_usr_pct"],
        "server_sys_pct": p["server_sys_pct"],
        "wrk_cpu_pct": p["wrk_cpu_pct"],
        "wrk_usr_pct": p["wrk_usr_pct"],
        "wrk_sys_pct": p["wrk_sys_pct"],
        "server_user_sec": round(user_sec, 4),
        "server_sys_sec": round(sys_sec, 4),
        "server_total_cpu_sec": round(total_cpu_sec, 4),
        "cpu_us_per_req": round(cpu_us_per_req, 3),
        "user_us_per_req": round(user_us_per_req, 3),
        "sys_us_per_req": round(sys_us_per_req, 3),
        "saturated_by_client": saturated_by_client,
        "status_flag": status_flag,
    }
    print(
        f"  [Round {round_num}] {label:14s}: {rec['req_per_sec']:10.2f} req/s | "
        f"CPU/req: {rec['cpu_us_per_req']:5.3f} us (usr {rec['user_us_per_req']:5.3f}, sys {rec['sys_us_per_req']:5.3f}) | "
        f"SrvCPU: {rec['server_cpu_pct']:5.1f}% (usr {rec['server_usr_pct']:4.1f}%, sys {rec['server_sys_pct']:4.1f}%) | "
        f"wrkCPU: {rec['wrk_cpu_pct']:5.1f}% | p99: {rec['p99_latency']:>7s} | {status_flag}"
    )
    return rec


def summarize_runs(runs: list) -> dict:
    rps = [r["req_per_sec"] for r in runs]
    cpu_req = [r["cpu_us_per_req"] for r in runs]
    usr_req = [r["user_us_per_req"] for r in runs]
    sys_req = [r["sys_us_per_req"] for r in runs]
    srv_cpu = [r["server_cpu_pct"] for r in runs]
    wrk_cpu = [r["wrk_cpu_pct"] for r in runs]
    return {
        "rps_median": round(statistics.median(rps), 2),
        "rps_min": round(min(rps), 2),
        "rps_max": round(max(rps), 2),
        "cpu_us_per_req_median": round(statistics.median(cpu_req), 3),
        "cpu_us_per_req_min": round(min(cpu_req), 3),
        "cpu_us_per_req_max": round(max(cpu_req), 3),
        "user_us_per_req_median": round(statistics.median(usr_req), 3),
        "sys_us_per_req_median": round(statistics.median(sys_req), 3),
        "server_cpu_pct_median": round(statistics.median(srv_cpu), 1),
        "wrk_cpu_pct_median": round(statistics.median(wrk_cpu), 1),
        "any_saturated_by_client": any(r["saturated_by_client"] for r in runs),
        "all_saturated_by_client": all(r["saturated_by_client"] for r in runs),
    }


def main():
    port_c = 18190
    port_g = 18191
    port_b = 18192

    proc_c = subprocess.Popen(
        ["taskset", "-c", "0", "./bench/c_control/server_c", str(port_c)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    proc_g = subprocess.Popen(
        ["taskset", "-c", "0", "./src/server_phase1", str(port_g), "30000", "10000", "1"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    c_runs = []
    g_runs = []
    bun_runs = []

    try:
        wait_for_port(port_c)
        wait_for_port(port_g)
        print("=== Running 7 Interleaved Rounds (C, Goose, C, Goose, ...) [Round 1 discarded as warmup] ===")
        for r in range(1, 8):
            c_rec = run_one_wrk(proc_c.pid, port_c, r, "Bare-C Control")
            time.sleep(0.5)
            g_rec = run_one_wrk(proc_g.pid, port_g, r, "Goose Honk")
            time.sleep(0.5)
            c_runs.append(c_rec)
            g_runs.append(g_rec)
    finally:
        proc_c.terminate()
        proc_g.terminate()
        proc_c.wait()
        proc_g.wait()

    # Now run the 5-line Bun.serve hello-world harness sanity check (1 warmup + 3 rounds)
    print("\n=== Running 5-line Bun.serve Hello-World (Harness Sanity Check, NOT a Comparison) ===")
    proc_b = subprocess.Popen(
        ["taskset", "-c", "0", BUN_BIN, "bench/bun_sanity.js", str(port_b)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        wait_for_port(port_b)
        for r in range(1, 5):
            b_rec = run_one_wrk(proc_b.pid, port_b, r, "Bun.serve (Sanity)")
            time.sleep(0.5)
            bun_runs.append(b_rec)
    finally:
        proc_b.terminate()
        proc_b.wait()

    c_kept = c_runs[1:]  # Rounds 2..7
    g_kept = g_runs[1:]  # Rounds 2..7
    b_kept = bun_runs[1:]  # Rounds 2..4

    c_sum = summarize_runs(c_kept)
    g_sum = summarize_runs(g_kept)
    b_sum = summarize_runs(b_kept)

    out_data = {
        "c_runs_all": c_runs,
        "goose_runs_all": g_runs,
        "bun_sanity_runs_all": bun_runs,
        "c_summary_r2_r7": c_sum,
        "goose_summary_r2_r7": g_sum,
        "bun_sanity_summary_r2_r4": b_sum,
    }
    with open("bench/step1b_interleaved_results.json", "w") as f:
        json.dump(out_data, f, indent=2)

    print("\n=== Summary (Rounds 2..7, Round 1 discarded; Indicative WSL2 Numbers) ===")
    print(f"Bare-C Control:  median {c_sum['rps_median']:.2f} req/s (min {c_sum['rps_min']:.2f}, max {c_sum['rps_max']:.2f}) | "
          f"CPU/req median {c_sum['cpu_us_per_req_median']:.3f} us (min {c_sum['cpu_us_per_req_min']:.3f}, max {c_sum['cpu_us_per_req_max']:.3f}; "
          f"usr {c_sum['user_us_per_req_median']:.3f}, sys {c_sum['sys_us_per_req_median']:.3f}) | "
          f"SrvCPU median {c_sum['server_cpu_pct_median']}% | wrkCPU median {c_sum['wrk_cpu_pct_median']}%")
    print(f"Goose Honk:      median {g_sum['rps_median']:.2f} req/s (min {g_sum['rps_min']:.2f}, max {g_sum['rps_max']:.2f}) | "
          f"CPU/req median {g_sum['cpu_us_per_req_median']:.3f} us (min {g_sum['cpu_us_per_req_min']:.3f}, max {g_sum['cpu_us_per_req_max']:.3f}; "
          f"usr {g_sum['user_us_per_req_median']:.3f}, sys {g_sum['sys_us_per_req_median']:.3f}) | "
          f"SrvCPU median {g_sum['server_cpu_pct_median']}% | wrkCPU median {g_sum['wrk_cpu_pct_median']}%")
    print(f"Bun Sanity:      median {b_sum['rps_median']:.2f} req/s (min {b_sum['rps_min']:.2f}, max {b_sum['rps_max']:.2f}) | "
          f"CPU/req median {b_sum['cpu_us_per_req_median']:.3f} us (usr {b_sum['user_us_per_req_median']:.3f}, sys {b_sum['sys_us_per_req_median']:.3f}) | "
          f"SrvCPU median {b_sum['server_cpu_pct_median']}% | wrkCPU median {b_sum['wrk_cpu_pct_median']}%")


if __name__ == "__main__":
    main()
