#!/usr/bin/env python3
"""
Requirement F: 10-minute RSS soak test (connect -> request -> close in a continuous loop).
Exercises:
  - Normal connect / GET /plaintext / close
  - Connect / split-recv POST /echo (forces lazy partial_rx malloc & free on drain/close) / close
Samples VmRSS and VmHWM from /proc/<pid>/status every 30 seconds for 600 seconds (10 minutes)
and asserts VmRSS stays flat after warm-up.
"""

import json
import socket
import subprocess
import sys
import time


def read_proc_mem(pid: int) -> dict:
    rss_kb = 0
    hwm_kb = 0
    with open(f"/proc/{pid}/status", "r") as f:
        for line in f:
            if line.startswith("VmRSS:"):
                rss_kb = int(line.split()[1])
            elif line.startswith("VmHWM:"):
                hwm_kb = int(line.split()[1])
    return {"VmRSS_kB": rss_kb, "VmHWM_kB": hwm_kb}


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
    raise RuntimeError(f"Port {port} not ready")


def main():
    server_bin = sys.argv[1] if len(sys.argv) > 1 else "./src/server_phase1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 18195
    duration_sec = int(sys.argv[3]) if len(sys.argv) > 3 else 600
    sample_interval = 30

    proc = subprocess.Popen(
        [server_bin, str(port), "30000", "10000", "1"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    samples = []
    iters = 0
    req_plain = b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    echo_body = b"LazyBufferSoakPayload0123456789_" * 64  # 2048 bytes
    req_echo_part1 = b"POST /echo HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: 2048\r\n\r\n" + echo_body[:512]
    req_echo_part2 = echo_body[512:]

    try:
        proc.stdout.readline()
        wait_for_port(port)

        start_time = time.monotonic()
        next_sample = 0

        print(f"=== Starting {duration_sec}s (10-minute) RSS Soak Test on {server_bin} (pid={proc.pid}) ===")
        while True:
            elapsed = time.monotonic() - start_time
            if elapsed >= next_sample or elapsed >= duration_sec:
                mem = read_proc_mem(proc.pid)
                rec = {
                    "elapsed_sec": int(round(elapsed)),
                    "connections_completed": iters,
                    "VmRSS_kB": mem["VmRSS_kB"],
                    "VmHWM_kB": mem["VmHWM_kB"],
                }
                samples.append(rec)
                print(
                    f"  [t={rec['elapsed_sec']:3d}s] completed={iters:7d} conns | "
                    f"VmRSS={rec['VmRSS_kB']} kB | VmHWM={rec['VmHWM_kB']} kB",
                    flush=True,
                )
                if elapsed >= duration_sec:
                    break
                next_sample += sample_interval

            # Connect -> request -> close
            with socket.create_connection(("127.0.0.1", port), timeout=2.0) as s:
                if (iters & 3) == 3:
                    # Every 4th connection exercises split-recv lazy partial_rx allocation + free
                    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    s.sendall(req_echo_part1)
                    time.sleep(0.001)
                    s.sendall(req_echo_part2)
                    data = b""
                    while b"\r\n\r\n" not in data or len(data.split(b"\r\n\r\n", 1)[1]) < 2048:
                        ch = s.recv(4096)
                        if not ch:
                            break
                        data += ch
                    assert b"200 OK" in data
                else:
                    s.sendall(req_plain)
                    data = s.recv(1024)
                    assert b"Hello, World!" in data
            iters += 1
            # Pace at ~250 conns/sec (~15,000 conns per 60s TIME_WAIT window) so Linux ephemeral ports never exhaust
            time.sleep(0.0035)

        warmup_rss = samples[1]["VmRSS_kB"]  # t=30s
        final_rss = samples[-1]["VmRSS_kB"]  # t=600s
        max_rss_after_warmup = max(s["VmRSS_kB"] for s in samples[1:])
        min_rss_after_warmup = min(s["VmRSS_kB"] for s in samples[1:])
        drift_kb = final_rss - warmup_rss

        summary = {
            "duration_sec": duration_sec,
            "total_connections_completed": iters,
            "initial_rss_kb": samples[0]["VmRSS_kB"],
            "warmup_30s_rss_kb": warmup_rss,
            "final_600s_rss_kb": final_rss,
            "min_rss_after_warmup_kb": min_rss_after_warmup,
            "max_rss_after_warmup_kb": max_rss_after_warmup,
            "rss_drift_after_warmup_kb": drift_kb,
            "samples": samples,
        }
        with open("bench/soak_10min_rss.json", "w") as f:
            json.dump(summary, f, indent=2)

        print(
            f"=== Soak Complete: {iters} connections in {duration_sec}s | "
            f"Warmup (30s) VmRSS={warmup_rss} kB -> Final (600s) VmRSS={final_rss} kB "
            f"(min={min_rss_after_warmup} kB, max={max_rss_after_warmup} kB, drift={drift_kb:+d} kB) ==="
        )
        assert abs(drift_kb) <= 128, f"VmRSS drifted by {drift_kb} kB after warmup!"
        print("[PASS] Requirement F: 10-minute RSS soak test stayed flat after warm-up!")
    finally:
        proc.terminate()
        proc.wait()


if __name__ == "__main__":
    main()
