#!/usr/bin/env python3
"""
Requirement G (Parts 1 & 2):
  1. Capture `curl -i` output of both the C control and the Goose Honk server
     Within the same second, save them to bench/curl_c_control.txt and
     bench/curl_goose_honk.txt, and confirm byte-equivalence in headers and size.
  2. Measure VmRSS and VmHWM properly for both servers at:
     - Idle baseline (0 connections)
     - 64 active connections (after each sends 1 HTTP request)
     - 1024 active connections (after each sends 1 HTTP request)
"""

import json
import socket
import subprocess
import time


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


def check_curl_equivalence():
    port_c = 18181
    port_g = 18182
    proc_c = subprocess.Popen(["./bench/c_control/server_c", str(port_c)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    proc_g = subprocess.Popen(["./src/server_minimal", str(port_g)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait_for_port(port_c)
        wait_for_port(port_g)

        # Wait until top of a fresh second so both servers format the exact same Date timestamp
        while (time.time() % 1.0) > 0.2:
            time.sleep(0.02)

        curl_c = subprocess.check_output(["curl", "-sS", "-i", f"http://127.0.0.1:{port_c}/plaintext"])
        curl_g = subprocess.check_output(["curl", "-sS", "-i", f"http://127.0.0.1:{port_g}/plaintext"])

        with open("bench/curl_c_control.txt", "wb") as f:
            f.write(curl_c)
        with open("bench/curl_goose_honk.txt", "wb") as f:
            f.write(curl_g)

        print(f"C control curl -i length:   {len(curl_c)} bytes")
        print(f"Goose Honk curl -i length:  {len(curl_g)} bytes")
        assert len(curl_c) == len(curl_g), f"Size mismatch: {len(curl_c)} != {len(curl_g)}"
        assert curl_c == curl_g, f"Byte mismatch:\nC:\n{curl_c!r}\nGoose:\n{curl_g!r}"
        print(f"[PASS] curl -i output of C control and Goose Honk are 100% byte-identical ({len(curl_c)} bytes)!")
    finally:
        proc_c.terminate()
        proc_g.terminate()
        proc_c.wait()
        proc_g.wait()


def measure_server_rss(cmd: list, port: int, label: str) -> dict:
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    socks = []
    try:
        # Wait for startup line on stdout (before any client connection touches slots)
        proc.stdout.readline()
        time.sleep(0.1)
        idle_mem = read_proc_mem(proc.pid)

        # Open 64 connections and exchange 1 keep-alive request on each
        req = b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n"
        for _ in range(64):
            s = socket.create_connection(("127.0.0.1", port), timeout=2.0)
            s.sendall(req)
            d = s.recv(1024)
            assert b"Hello, World!" in d
            socks.append(s)
        time.sleep(0.05)
        c64_mem = read_proc_mem(proc.pid)

        # Open 960 more connections (total 1024 active connections) and exchange 1 request on each
        for _ in range(1024 - 64):
            s = socket.create_connection(("127.0.0.1", port), timeout=2.0)
            s.sendall(req)
            d = s.recv(1024)
            assert b"Hello, World!" in d
            socks.append(s)
        time.sleep(0.05)
        c1024_mem = read_proc_mem(proc.pid)

        res = {
            "label": label,
            "idle": idle_mem,
            "conns_64": c64_mem,
            "conns_1024": c1024_mem,
        }
        print(f"RSS for {label}:")
        print(f"  Idle (0 conns):     VmRSS = {idle_mem['VmRSS_kB']} kB, VmHWM = {idle_mem['VmHWM_kB']} kB")
        print(f"  64 active conns:    VmRSS = {c64_mem['VmRSS_kB']} kB, VmHWM = {c64_mem['VmHWM_kB']} kB")
        print(f"  1024 active conns:  VmRSS = {c1024_mem['VmRSS_kB']} kB, VmHWM = {c1024_mem['VmHWM_kB']} kB")
        return res
    finally:
        for s in socks:
            try:
                s.close()
            except Exception:
                pass
        proc.terminate()
        proc.wait()


def main():
    check_curl_equivalence()
    c_rss = measure_server_rss(["./bench/c_control/server_c", "18183"], 18183, "Bare-C Control")
    g_rss = measure_server_rss(["./src/server_minimal", "18184"], 18184, "Honk minimal")
    with open("bench/rss_measurements.json", "w") as f:
        json.dump({"c_control": c_rss, "goose_honk": g_rss}, f, indent=2)


if __name__ == "__main__":
    main()
