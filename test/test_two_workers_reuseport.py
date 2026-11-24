#!/usr/bin/env python3
"""
Requirement H: Two-worker smoke test with SO_REUSEPORT on separate physical cores.
Verifies:
  1. Worker 0 is pinned to CPU 0 (Physical Core 0) and Worker 1 is pinned to CPU 2 (Physical Core 1)
     via /proc/<pid>/task/<tid>/status (Cpus_allowed_list).
  2. Both workers bind & listen on the same port via SO_REUSEPORT and both accept connections.
  3. Connections are spread across both workers by the kernel.
  4. Thread-local counters (accepted=) are independent per worker (zero shared mutable state),
     and their sum equals the exact number of connections made.
"""

import os
import socket
import subprocess
import sys
import time


def parse_stats(body: str) -> dict:
    out = {}
    for part in body.strip().split():
        if "=" in part:
            k, v = part.split("=", 1)
            out[k] = int(v)
    return out


def fetch_stats(port: int) -> dict:
    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as s:
        s.sendall(b"GET /stats HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        data = b""
        while True:
            ch = s.recv(4096)
            if not ch:
                break
            data += ch
    assert b"HTTP/1.1 200 OK" in data, f"Unexpected response: {data!r}"
    body = data.split(b"\r\n\r\n", 1)[1].decode("utf-8", errors="replace")
    return parse_stats(body)


def get_worker_cpu_affinities(pid: int) -> list:
    task_dir = f"/proc/{pid}/task"
    affinities = []
    for tid in sorted(os.listdir(task_dir)):
        status_path = f"{task_dir}/{tid}/status"
        try:
            with open(status_path, "r") as f:
                for line in f:
                    if line.startswith("Cpus_allowed_list:"):
                        affinities.append((int(tid), line.split(":", 1)[1].strip()))
        except OSError:
            pass
    return affinities


def main():
    server_bin = sys.argv[1] if len(sys.argv) > 1 else "./src/server_minimal"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 18170
    total_conns = 200

    proc = subprocess.Popen(
        [server_bin, str(port), "30000", "10000", "2"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        line = proc.stdout.readline()
        assert "workers=2" in line, f"Unexpected startup line: {line}"
        time.sleep(0.15)

        affinities = get_worker_cpu_affinities(proc.pid)
        cpu_lists = [cpu for _, cpu in affinities]
        print(f"Process {proc.pid} thread affinities (tid, Cpus_allowed_list): {affinities}")
        assert "0" in cpu_lists and "2" in cpu_lists, (
            f"Expected worker threads pinned to physical Core 0 (CPU 0) and Core 1 (CPU 2), got {affinities}"
        )

        hits = {0: 0, 1: 0}
        max_accepted = {0: 0, 1: 0}

        for _ in range(total_conns):
            st = fetch_stats(port)
            w = st["worker"]
            assert w in (0, 1), f"Invalid worker id: {st}"
            hits[w] += 1
            max_accepted[w] = max(max_accepted[w], st["accepted"])

        print(f"Total connections: {total_conns}")
        print(f"  Worker 0 (CPU 0, Physical Core 0): {hits[0]} responses, thread-local accepted={max_accepted[0]}")
        print(f"  Worker 1 (CPU 2, Physical Core 1): {hits[1]} responses, thread-local accepted={max_accepted[1]}")

        assert hits[0] >= 40 and hits[1] >= 40, f"Connections not spread across both workers: {hits}"
        assert max_accepted[0] == hits[0] and max_accepted[1] == hits[1], (
            f"Thread-local accepted counters do not match per-worker hits: max_accepted={max_accepted}, hits={hits}"
        )
        assert max_accepted[0] + max_accepted[1] == total_conns
        print("[PASS] Requirement H: Two-worker SO_REUSEPORT smoke test on separate physical cores (CPU 0 & CPU 2)")
    finally:
        proc.terminate()
        try:
            proc.communicate(timeout=2.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()


if __name__ == "__main__":
    main()
