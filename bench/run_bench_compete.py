#!/usr/bin/env python3
"""
Cross-framework benchmark (Release builds, single-core pinned).

Re-runnable on any Linux box with one command: python3 bench/run_bench_compete.py
(from the repo root; contenders must be built/installed first, see README).

Contenders x Workloads:
  W1 GET /plaintext          (all 10 incl. bare-C control)
  W2 GET /json               (9, no bare-C)
  W3 GET /users/:id?role=    (+ X-Frame-Bench middleware header)
  W4 POST /users             (validate -> 201 / 400)

Protocol: taskset -c 0 servers (1 worker), wrk -t2 -c64 -d5s on -c 4,6,
3s warm-up per server per workload, 5 interleaved round-robin rounds,
/proc CPU us/req + pidstat saturation, RSS matrix, cold start, footprint.
"""

import json
import os
import re
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_bench_transport import (  # noqa: E402
    CLK_TCK, PIDSTAT_BIN, WRK_BIN, parse_pidstat_averages, parse_wrk_output,
    read_proc_cpu_ticks, summarize_runs, wait_for_port,
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUN = os.path.join(os.path.expanduser("~"), ".local", "bin", "bun")
COMP = os.path.join(ROOT, "bench", "competitors")

CONTENDERS = [
    {"key": "c_control", "label": "Bare-C Control", "tier": "native",
     "dir": ROOT, "cmd": ["./bench/c_control/server_c", "{port}"],
     "env": {}, "workloads": [1]},
    {"key": "honk", "label": "Honk (Goose)", "tier": "native",
     "dir": ROOT, "cmd": ["./src/server", "{port}", "30000", "10000", "1", "1"],
     "env": {}, "workloads": [1, 2, 3, 4]},
    {"key": "axum", "label": "Rust Axum", "tier": "native",
     "dir": os.path.join(COMP, "rust-axum"),
     "cmd": ["./target/release/axum-bench", "{port}"],
     "env": {}, "workloads": [1, 2, 3, 4]},
    {"key": "go", "label": "Go net/http", "tier": "cloud",
     "dir": os.path.join(COMP, "go-std"), "cmd": ["./server", "{port}"],
     "env": {"GOMAXPROCS": "1"}, "workloads": [1, 2, 3, 4]},
    {"key": "bun", "label": "Bun.serve", "tier": "bun",
     "dir": os.path.join(COMP, "bun-raw"), "cmd": [BUN, "./server.js", "{port}"],
     "env": {}, "workloads": [1, 2, 3, 4]},
    {"key": "elysia", "label": "Elysia (Bun)", "tier": "bun",
     "dir": os.path.join(COMP, "elysia-bun"), "cmd": [BUN, "./server.js", "{port}"],
     "env": {}, "workloads": [1, 2, 3, 4]},
    {"key": "hono", "label": "Hono (Bun)", "tier": "bun",
     "dir": os.path.join(COMP, "hono-bun"), "cmd": [BUN, "./server.js", "{port}"],
     "env": {}, "workloads": [1, 2, 3, 4]},
    {"key": "fastify", "label": "Fastify (Node)", "tier": "node-py",
     "dir": os.path.join(COMP, "fastify-node"), "cmd": ["node", "./server.js", "{port}"],
     "env": {}, "workloads": [1, 2, 3, 4]},
    {"key": "express", "label": "Express (Node)", "tier": "node-py",
     "dir": os.path.join(COMP, "express-node"), "cmd": ["node", "./server.js", "{port}"],
     "env": {}, "workloads": [1, 2, 3, 4]},
    {"key": "fastapi", "label": "FastAPI (uvicorn)", "tier": "node-py",
     "dir": os.path.join(COMP, "fastapi-py"),
     "cmd": ["./venv/bin/uvicorn", "app:app", "--host", "127.0.0.1",
             "--port", "{port}", "--workers", "1", "--no-access-log"],
     "env": {}, "workloads": [1, 2, 3, 4]},
]

WORKLOADS = {
    1: {"name": "W1 plaintext", "method": "GET", "target": "/plaintext", "script": None},
    2: {"name": "W2 json", "method": "GET", "target": "/json", "script": None},
    3: {"name": "W3 route+query+mw", "method": "GET", "target": "/users/123?role=admin",
        "script": None},
    4: {"name": "W4 post-validate", "method": "POST", "target": "/users",
        "script": "bench/post_users.lua"},
}

W4_OK = b'{"name":"alice","age":30,"active":true}'
W4_BAD = [
    b'{"name":"","age":30,"active":true}',
    b'{"name":"a","age":"30","active":true}',
    b'{oops',
    b'{"name":"a","age":30}',
    b'{"name":"a","age":30,"active":1}',
    b'{"name":"a","age":30.5,"active":true}',
]

BASE_PORT = 18501


def spawn_contender(cont, port):
    cmd = ["taskset", "-c", "0"] + [a.format(port=port) for a in cont["cmd"]]
    env = dict(os.environ)
    env.update(cont["env"])
    log = open(f"/tmp/p3_{cont['key']}.log", "wb")
    proc = subprocess.Popen(cmd, cwd=cont["dir"], stdout=log, stderr=subprocess.STDOUT,
                            env=env)
    return proc, log


def wait_ready(port, timeout=60.0):
    """Poll until GET /plaintext returns 200; returns elapsed seconds."""
    t0 = time.time()
    deadline = t0 + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1.0) as s:
                s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                data = b""
                while b"\r\n\r\n" not in data:
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                if data.startswith(b"HTTP/1.1 200"):
                    return time.time() - t0
        except OSError:
            pass
        time.sleep(0.1)
    raise RuntimeError(f"port {port} never became ready")


def http_roundtrip(port, payload, timeout=5.0):
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as s:
        s.sendall(payload)
        f = s.makefile("rb")
        status = f.readline().decode("latin1")
        code = int(status.split(" ")[1])
        headers = {}
        while True:
            line = f.readline()
            if line in (b"\r\n", b"\n", b""):
                break
            k, v = line.split(b":", 1)
            headers[k.strip().lower()] = v.strip()
        body = f.read(int(headers.get(b"content-length", b"0") or 0))
        return code, headers, body

def preflight_contender(cont, port):
    """Verify exact workload behavior; returns (cold_start_s, curl_w1_bytes)."""
    proc, log = spawn_contender(cont, port)
    try:
        t0 = time.time()
        wait_ready(port)
        cold_start = time.time() - t0
        wl = cont["workloads"]
        # W1.
        code, hdrs, body = http_roundtrip(
            port, b"GET /plaintext HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        assert code == 200 and body == b"Hello, World!", (cont["key"], code, body)
        assert b"text/plain" in hdrs[b"content-type"], (cont["key"], hdrs)
        assert b"x-frame-bench" not in hdrs, (cont["key"], "W1 must carry no hook header")
        raw_w1 = subprocess.run(
            ["curl", "-s", "-i", f"http://127.0.0.1:{port}/plaintext"],
            capture_output=True, timeout=5).stdout
        with open(f"bench/preflight_{cont['key']}_w1.txt", "wb") as f:
            f.write(raw_w1)
        if 2 in wl:
            code, hdrs, body = http_roundtrip(
                port, b"GET /json HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            assert code == 200, (cont["key"], code)
            assert b"application/json" in hdrs[b"content-type"], (cont["key"], hdrs)
            assert json.loads(body) == {"message": "Hello, World!"}, (cont["key"], body)
        if 3 in wl:
            code, hdrs, body = http_roundtrip(
                port, b"GET /users/42?role=admin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            assert code == 200, (cont["key"], code)
            assert hdrs.get(b"x-frame-bench") == b"1", (cont["key"], hdrs)
            assert json.loads(body) == {"id": "42", "role": "admin"}, (cont["key"], body)
        if 4 in wl:
            code, hdrs, body = http_roundtrip(
                port, b"POST /users HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                       b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(W4_OK) + W4_OK)
            assert code == 201, (cont["key"], code, body)
            assert json.loads(body) == {"created": True, "name": "alice", "age": 30}, \
                (cont["key"], body)
            for bad in W4_BAD:
                code, _, body = http_roundtrip(
                    port, b"POST /users HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                           b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(bad) + bad)
                assert code == 400, (cont["key"], bad, code, body)
        print(f"  [PREFLIGHT-PASS] {cont['label']:18s} cold-start {cold_start*1000:7.1f} ms")
        return cold_start, raw_w1
    finally:
        proc.terminate()
        proc.wait()
        log.close()


def run_wrk(server_pid, url, script, seconds, label):
    cmd = ["taskset", "-c", "4,6", WRK_BIN, "-t2", "-c64", f"-d{seconds}s", "--latency"]
    if script:
        cmd += ["-s", os.path.join(ROOT, script)]
    cmd.append(url)
    u0, s0 = read_proc_cpu_ticks(server_pid)
    wrk_proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(0.4)
    n_samples = max(int(seconds) - 1, 1)
    pidstat_proc = subprocess.Popen(
        [PIDSTAT_BIN, "-u", "-p", f"{server_pid},{wrk_proc.pid}", "1", str(n_samples)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    wrk_out, wrk_err = wrk_proc.communicate()
    u1, s1 = read_proc_cpu_ticks(server_pid)
    pidstat_out, _ = pidstat_proc.communicate()
    w = parse_wrk_output(wrk_out)
    p = parse_pidstat_averages(pidstat_out, server_pid, wrk_proc.pid)
    m_p50 = re.search(r"50%\s+([0-9.]+)(us|ms|s)", wrk_out)
    user_sec = (u1 - u0) / CLK_TCK
    sys_sec = (s1 - s0) / CLK_TCK
    reqs = max(w["total_requests"], 1)
    flag = "SATURATED-BY-CLIENT" if p["server_cpu_pct"] < 85.0 else "SERVER-CORE-BUSY"
    return {
        "req_per_sec": w["req_per_sec"],
        "total_requests": w["total_requests"],
        "p50_latency": f"{m_p50.group(1)}{m_p50.group(2)}" if m_p50 else "N/A",
        "p99_latency": w["p99_latency"],
        "server_cpu_pct": p["server_cpu_pct"],
        "server_usr_pct": p["server_usr_pct"],
        "server_sys_pct": p["server_sys_pct"],
        "wrk_cpu_pct": p["wrk_cpu_pct"],
        "cpu_us_per_req": round(((user_sec + sys_sec) * 1e6) / reqs, 3),
        "user_us_per_req": round((user_sec * 1e6) / reqs, 3),
        "sys_us_per_req": round((sys_sec * 1e6) / reqs, 3),
        "status_flag": flag,
        "saturated_by_client": flag == "SATURATED-BY-CLIENT",
        "wrk_stderr_tail": wrk_err[-300:] if reqs <= 1 else "",
    }


def benchmark_workload(wid, ports):
    w = WORKLOADS[wid]
    active = [c for c in CONTENDERS if wid in c["workloads"]]
    print(f"\n=== Workload {wid}: {w['name']} ({len(active)} contenders) ===")
    procs = {}
    logs = {}
    try:
        for c in active:
            proc, log = spawn_contender(c, ports[c["key"]])
            procs[c["key"]] = proc
            logs[c["key"]] = log
        for c in active:
            wait_ready(ports[c["key"]])
        print("  -- warm-up 3s each --")
        for c in active:
            url = f"http://127.0.0.1:{ports[c['key']]}{w['target']}"
            run_wrk(procs[c["key"]].pid, url, w["script"], 3, "warmup")
        print("  -- 5 measured rounds (round-robin) --")
        runs = {c["key"]: [] for c in active}
        for r in range(1, 6):
            for c in active:
                url = f"http://127.0.0.1:{ports[c['key']]}{w['target']}"
                rec = run_wrk(procs[c["key"]].pid, url, w["script"], 5, c["key"])
                rec["round"] = r
                runs[c["key"]].append(rec)
                print(f"  [W{wid} R{r}] {c['label']:18s}: {rec['req_per_sec']:10.2f} req/s | "
                      f"CPU {rec['cpu_us_per_req']:6.3f} (u{rec['user_us_per_req']:6.3f}/"
                      f"s{rec['sys_us_per_req']:6.3f}) | srv {rec['server_cpu_pct']:5.1f}% | "
                      f"wrk {rec['wrk_cpu_pct']:5.1f}% | p50 {rec['p50_latency']:>7s} "
                      f"p99 {rec['p99_latency']:>7s} | {rec['status_flag']}")
        return runs
    finally:
        for proc in procs.values():
            proc.terminate()
        for proc in procs.values():
            proc.wait()
        for log in logs.values():
            log.close()


def read_mem(pid):
    rss = hwm = 0
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith("VmRSS:"):
                rss = int(line.split()[1])
            elif line.startswith("VmHWM:"):
                hwm = int(line.split()[1])
    return rss, hwm


def measure_rss(cont, port):
    proc, log = spawn_contender(cont, port)
    try:
        wait_ready(port)
        out = {}
        rss, hwm = read_mem(proc.pid)
        out["idle"] = {"VmRSS_kB": rss, "VmHWM_kB": hwm}
        conns = []
        for _ in range(64):
            s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
            s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n")
            s.recv(256)
            conns.append(s)
        time.sleep(0.3)
        rss, hwm = read_mem(proc.pid)
        out["conns_64"] = {"VmRSS_kB": rss, "VmHWM_kB": hwm}
        for _ in range(64, 512):
            s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
            s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n")
            s.recv(256)
            conns.append(s)
        # Load burst while 512 conns are open, then measure.
        url = f"http://127.0.0.1:{port}/plaintext"
        subprocess.run(["taskset", "-c", "4,6", WRK_BIN, "-t2", "-c64", "-d3s", url],
                       capture_output=True, timeout=15)
        time.sleep(0.3)
        rss, hwm = read_mem(proc.pid)
        out["conns_512_after_load"] = {"VmRSS_kB": rss, "VmHWM_kB": hwm}
        for s in conns:
            s.close()
        print(f"  [RSS] {cont['label']:18s}: idle {out['idle']['VmRSS_kB']} kB | "
              f"64c {out['conns_64']['VmRSS_kB']} kB | 512c+load {out['conns_512_after_load']['VmRSS_kB']} kB "
              f"(HWM {out['conns_512_after_load']['VmHWM_kB']} kB)")
        return out
    finally:
        proc.terminate()
        proc.wait()
        log.close()


def du_bytes(path):
    out = subprocess.run(["du", "-sb", path], capture_output=True, text=True)
    return int(out.stdout.split()[0])


def measure_footprint():
    fp = {}
    fp["c_control"] = {"kind": "binary", "bytes": du_bytes(f"{ROOT}/bench/c_control/server_c")}
    fp["honk"] = {"kind": "binary", "bytes": du_bytes(f"{ROOT}/src/server")}
    fp["axum"] = {"kind": "binary",
                  "bytes": du_bytes(f"{COMP}/rust-axum/target/release/axum-bench")}
    fp["go"] = {"kind": "binary", "bytes": du_bytes(f"{COMP}/go-std/server")}
    bun_bin = du_bytes(BUN)
    fp["bun"] = {"kind": "shared bun runtime", "bytes": bun_bin}
    for key in ("elysia", "hono", "fastify", "express"):
        d = {"elysia": "elysia-bun", "hono": "hono-bun", "fastify": "fastify-node",
             "express": "express-node"}[key]
        fp[key] = {"kind": "node_modules (+runtime)",
                   "bytes": du_bytes(f"{COMP}/{d}/node_modules")}
    fp["fastapi"] = {"kind": "venv", "bytes": du_bytes(f"{COMP}/fastapi-py/venv")}
    return fp


def main():
    t_start = time.time()
    ports = {c["key"]: BASE_PORT + i for i, c in enumerate(CONTENDERS)}
    results = {"contenders": {c["key"]: c["label"] for c in CONTENDERS},
               "ports": ports, "cold_start_s": {}, "runs": {}, "summaries": {},
               "rss": {}, "footprint": {}}

    print("=== Preflight parity (200 + 400 on every contender) ===")
    for c in CONTENDERS:
        cold, _ = preflight_contender(c, ports[c["key"]])
        results["cold_start_s"][c["key"]] = round(cold, 3)

    for wid in (1, 2, 3, 4):
        runs = benchmark_workload(wid, ports)
        results["runs"][f"W{wid}"] = runs
        results["summaries"][f"W{wid}"] = {k: summarize_runs(v) for k, v in runs.items()}
        with open("bench/bench_compete_results.partial.json", "w") as f:
            json.dump(results, f, indent=2)
    print("\n=== RSS matrix (idle / 64 / 512+load) ===")
    for c in CONTENDERS:
        results["rss"][c["key"]] = measure_rss(c, ports[c["key"]])

    print("\n=== Footprint ===")
    results["footprint"] = measure_footprint()
    for k, v in results["footprint"].items():
        print(f"  {k:10s}: {v['bytes']/1048576:8.2f} MiB ({v['kind']})")

    with open("bench/bench_compete_results.json", "w") as f:
        json.dump(results, f, indent=2)

    print("\n=== Throughput medians (req/s, 5 rounds) ===")
    for wid in (1, 2, 3, 4):
        print(f"  -- W{wid} {WORKLOADS[wid]['name']} --")
        rows = sorted(results["summaries"][f"W{wid}"].items(),
                      key=lambda kv: -kv[1]["rps_median"])
        for key, s in rows:
            print(f"    {key:10s}: {s['rps_median']:10.2f} "
                  f"(min {s['rps_min']:10.2f}, max {s['rps_max']:10.2f}) | "
                  f"CPU {s['cpu_us_per_req_median']:.3f} "
                  f"(u{s['user_us_per_req_median']:.3f}/s{s['sys_us_per_req_median']:.3f}) | "
                  f"srv {s['server_cpu_pct_median']}% wrk {s['wrk_cpu_pct_median']}%")
    print(f"\nTotal harness time: {(time.time()-t_start)/60:.1f} min")


if __name__ == "__main__":
    main()
