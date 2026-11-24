#!/usr/bin/env python3
"""
Phase 2 framework correctness suite (Release + ASan+UBSan+LSan).

Covers: static routes + /plaintext byte shape, :params (single + multi),
query parsing, case-insensitive request headers, custom response headers,
404 vs 405, middleware order + auth short-circuit, HEAD, typed json::Reader
POST (valid/nested/escaped/unknown-keys + all 400 classes + 413), DOM POST,
keep-alive + split-recv JSON + pipelined mix, /stats + /large, and a
2-worker SO_REUSEPORT test with clean shutdown (exit 0, LSan runs).
"""

import json as pyjson
import os
import socket
import subprocess
import sys
import time


def read_response(f, skip_body=False):
    """Read one HTTP/1.1 response from a buffered socket file."""
    status_line = f.readline().decode("latin1")
    assert status_line.startswith("HTTP/1.1 "), f"bad status line: {status_line!r}"
    code = int(status_line.split(" ")[1])
    headers = {}
    order = []
    raw = status_line.encode("latin1")
    while True:
        line = f.readline()
        assert line, "EOF in headers"
        raw += line
        if line in (b"\r\n", b"\n"):
            break
        k, v = line.split(b":", 1)
        k = k.strip().lower()
        headers[k] = v.strip()
        order.append(k)
    body = b""
    if not skip_body:
        clen = int(headers.get(b"content-length", b"0"))
        while len(body) < clen:
            chunk = f.read(clen - len(body))
            assert chunk, "EOF in body"
            body += chunk
    return code, headers, order, raw, body


def get(port, target, headers=None, method="GET", keepalive=True):
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    f = s.makefile("rb")
    lines = [f"{method} {target} HTTP/1.1", "Host: localhost"]
    for k, v in (headers or {}).items():
        lines.append(f"{k}: {v}")
    if not keepalive:
        lines.append("Connection: close")
    req = ("\r\n".join(lines) + "\r\n\r\n").encode()
    s.sendall(req)
    return s, f, req


def post(port, target, body, headers=None, keepalive=True):
    hdrs = {"Content-Length": str(len(body))}
    hdrs.update(headers or {})
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    f = s.makefile("rb")
    lines = [f"POST {target} HTTP/1.1", "Host: localhost"]
    for k, v in hdrs.items():
        lines.append(f"{k}: {v}")
    if not keepalive:
        lines.append("Connection: close")
    s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode() + body)
    return s, f


def test_01_static_and_byte_shape(port):
    for target in (b"/", b"/plaintext"):
        s, f, _ = get(port, target.decode())
        code, hdrs, order, raw, body = read_response(f)
        assert code == 200, (target, code)
        assert body == b"Hello, World!", body
        assert hdrs[b"content-type"] == b"text/plain"
        assert hdrs[b"content-length"] == b"13"
        assert len(hdrs[b"date"]) == 29, hdrs[b"date"]
        # Hot-path exemption: no middleware headers on / and /plaintext.
        assert b"x-mw-1" not in hdrs and b"x-worker" not in hdrs, order
        assert order == [b"content-type", b"date", b"content-length"], order
        assert len(raw) + len(body) == 115, len(raw) + len(body)
        assert raw.startswith(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nDate: ")
        s.close()
    print("  [PASS] test_01_static_and_byte_shape")


def test_02_params_query_headers(port):
    # Single param.
    s, f, _ = get(port, "/users/42")
    code, hdrs, order, raw, body = read_response(f)
    assert code == 200 and pyjson.loads(body) == {"id": "42", "verbose": False}, (code, body)
    assert hdrs[b"content-type"] == b"application/json"
    # Custom response headers from middleware chain, in execution order.
    assert hdrs[b"x-mw-1"] == b"one" and hdrs[b"x-mw-2"] == b"two", order
    assert hdrs[b"x-worker"] == b"0", hdrs
    assert raw.index(b"X-MW-1") < raw.index(b"X-MW-2") < raw.index(b"X-Worker"), raw
    s.close()
    # Param + query flag.
    s, f, _ = get(port, "/users/7?verbose=1")
    code, _, _, _, body = read_response(f)
    assert code == 200 and pyjson.loads(body) == {"id": "7", "verbose": True}, (code, body)
    s.close()
    # Empty / missing param -> 404.
    for target in ("/users/", "/users"):
        s, f, _ = get(port, target)
        code, _, _, _, body = read_response(f)
        assert code == 404, (target, code)
        s.close()
    # Multi-param route.
    s, f, _ = get(port, "/orgs/acme/repos/honk")
    code, _, _, _, body = read_response(f)
    assert code == 200 and pyjson.loads(body) == {"org": "acme", "repo": "honk"}, (code, body)
    s.close()
    for target in ("/orgs/a/repos/", "/orgs//repos/x", "/orgs/a", "/orgs/a/repo/x"):
        s, f, _ = get(port, target)
        code, _, _, _, _ = read_response(f)
        assert code == 404, (target, code)
        s.close()
    # Query parsing.
    cases = [
        ("/greet", b"Hello, World!"),
        ("/greet?name=Ada", b"Hello, Ada!"),
        ("/greet?name=", b"Hello, World!"),
        ("/greet?a=1&name=Bo&x=2", b"Hello, Bo!"),
        ("/greet?a=1&name=Bo&name=ignored", b"Hello, Bo!"),
    ]
    for target, want in cases:
        s, f, _ = get(port, target)
        code, _, _, _, body = read_response(f)
        assert code == 200 and body == want, (target, code, body)
        s.close()
    # Case-insensitive request header lookup.
    s, f, _ = get(port, "/ua", {"User-Agent": "TestAgent/1.0"})
    code, _, _, _, body = read_response(f)
    assert code == 200 and body == b"TestAgent/1.0", body
    s.close()
    s, f, _ = get(port, "/ua", {"uSeR-aGeNt": "lower-case-name"})
    code, _, _, _, body = read_response(f)
    assert code == 200 and body == b"lower-case-name", body
    s.close()
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    s.sendall(b"GET /ua HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    f = s.makefile("rb")
    code, _, _, _, body = read_response(f)
    assert code == 200 and body == b"unknown", body
    s.close()
    print("  [PASS] test_02_params_query_headers")


def test_03_404_vs_405(port):
    cases_404 = [("GET", "/nope"), ("POST", "/nope"), ("PUT", "/nope"),
                 ("DELETE", "/nope"), ("FOO", "/nope")]
    for method, target in cases_404:
        s, f, _ = get(port, target, method=method)
        code, _, _, _, body = read_response(f)
        assert code == 404 and body == b"Not Found", (method, target, code)
        s.close()
    cases_405 = [("POST", "/plaintext"), ("PUT", "/json"), ("DELETE", "/users/1"),
                 ("PATCH", "/greet"), ("OPTIONS", "/"), ("FOO", "/json"),
                 ("GET", "/api/typed"), ("DELETE", "/api/dom"), ("POST", "/users/1")]
    for method, target in cases_405:
        s, f, _ = get(port, target, method=method)
        code, _, _, _, body = read_response(f)
        assert code == 405 and body == b"Method Not Allowed", (method, target, code)
        s.close()
    # PUT route with param works.
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    s.sendall(b"PUT /users/9 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    f = s.makefile("rb")
    code, _, _, _, body = read_response(f)
    assert code == 200 and pyjson.loads(body) == {"id": "9", "updated": True}, (code, body)
    s.close()
    print("  [PASS] test_03_404_vs_405")


def test_04_middleware_auth(port):
    # No auth -> 401 short-circuit, handler never ran.
    s, f, _ = get(port, "/admin/secret")
    code, hdrs, order, raw, body = read_response(f)
    assert code == 401 and body == b"Unauthorized", (code, body)
    assert b"x-mw-1" in hdrs and b"x-mw-2" in hdrs, order
    assert b"x-handler-ran" not in hdrs, order
    assert raw.index(b"X-MW-1") < raw.index(b"X-MW-2") < raw.index(b"X-Worker"), raw
    s.close()
    # With auth -> 200, handler ran, user decorated from header.
    s, f, _ = get(port, "/admin/secret", {"Authorization": "Bearer ada"})
    code, hdrs, _, _, body = read_response(f)
    assert code == 200 and body == b"top-secret for Bearer ada", (code, body)
    assert hdrs[b"x-handler-ran"] == b"1", hdrs
    s.close()
    print("  [PASS] test_04_middleware_auth")


def test_05_head(port):
    # HEAD mirrors GET headers with Content-Length but no body.
    for target in ("/plaintext", "/json", "/users/3"):
        s, f, _ = get(port, target)
        code_g, hdrs_g, _, _, body_g = read_response(f)
        s.close()
        s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
        req = f"HEAD {target} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode()
        s.sendall(req)
        f = s.makefile("rb")
        code_h, hdrs_h, _, _, _ = read_response(f, skip_body=True)
        assert code_h == 200, (target, code_h)
        assert hdrs_h[b"content-length"] == str(len(body_g)).encode(), (target, hdrs_h)
        assert hdrs_h[b"content-type"] == hdrs_g[b"content-type"], (target,)
        rest = f.read()
        assert rest == b"", (target, rest)
        s.close()
    # HEAD on unknown path -> 404 with no body bytes.
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    s.sendall(b"HEAD /nope HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    f = s.makefile("rb")
    code, hdrs, _, _, _ = read_response(f, skip_body=True)
    assert code == 404 and hdrs[b"content-length"] == b"9", (code, hdrs)
    assert f.read() == b""
    s.close()
    print("  [PASS] test_05_head")


TYPED_FULL = (b'{"name": "a\\"b\\\\c", "age": 30, "score": 9.5, "tags": ["x", "y"],'
              b' "address": {"city": "SF", "zip": 94105, "junk": [1]},'
              b' "unknown1": 1, "unknown2": {"deep": [1, 2, {"z": null}]}}')


def test_06_typed_json(port):
    # Valid full object: nested struct, array, escapes via scratch, unknown-key skip.
    s, f = post(port, "/api/typed", TYPED_FULL)
    code, hdrs, _, _, body = read_response(f)
    assert code == 200, (code, body)
    assert hdrs[b"content-type"] == b"application/json"
    assert hdrs[b"x-api-version"] == b"2", hdrs
    got = pyjson.loads(body)
    assert got == {"ok": True, "name": 'a"b\\c', "age": 30, "score": 9.5,
                   "tags": 2, "city": "SF"}, got
    s.close()
    # Minimal object: only required fields.
    s, f = post(port, "/api/typed", b'{"age": 1, "name": "x"}')
    code, _, _, _, body = read_response(f)
    assert code == 200 and pyjson.loads(body) == {"ok": True, "name": "x", "age": 1, "tags": 0}, (code, body)
    s.close()
    # >8 tags: capped at 8, extras skipped.
    big = b'{"name": "n", "age": 1, "tags": ["a","b","c","d","e","f","g","h","i","j"]}'
    s, f = post(port, "/api/typed", big)
    code, _, _, _, body = read_response(f)
    assert code == 200 and pyjson.loads(body)["tags"] == 8, (code, body)
    s.close()
    # Every invalid class -> 400 (connection stays alive: app-level error).
    bad_cases = [
        b'{"age": 1}',                    # missing name
        b'{"name": "x"}',                 # missing age
        b'{"name": 123, "age": 1}',       # wrong type: name
        b'{"name": "x", "age": "1"}',     # wrong type: age string
        b'{"name": "x", "age": 1.5}',     # wrong type: age fraction
        b'{"name": "x", "age": 1, "tags": "x"}',      # tags not array
        b'{"name": "x", "age": 1, "address": []}',    # address not object
        b'{"name": "x", "age": 1, "score": "hi"}',    # score not number
        b'{"name": ',                     # truncated
        b'{"name": "x", "age": 1} garbage',  # trailing tokens
        b'not json at all',               # malformed
        b'',                              # empty body
        b'[1, 2, 3]',                     # top-level array, want object
    ]
    for payload in bad_cases:
        s, f = post(port, "/api/typed", payload)
        code, _, _, _, body = read_response(f)
        assert code == 400 and body == b"Bad Request", (payload, code, body)
        # Connection still alive after app-level 400.
        s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        code2, _, _, _, body2 = read_response(f)
        assert code2 == 200 and body2 == b"Hello, World!", (payload, code2)
        s.close()
    # >1 MiB Content-Length -> 413 protocol reject + close.
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    s.sendall(b"POST /api/typed HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048577\r\n\r\n" + b"x" * 100)
    f = s.makefile("rb")
    code, _, _, _, body = read_response(f)
    assert code == 413 and body == b"Payload Too Large", (code, body)
    assert f.read() == b"", "413 must close connection"
    s.close()
    print("  [PASS] test_06_typed_json")


def test_07_dom_json(port):
    s, f = post(port, "/api/dom", b'{"msg": "hi", "a": 1, "b": [1, 2]}')
    code, hdrs, _, _, body = read_response(f)
    assert code == 200, (code, body)
    assert hdrs[b"content-type"] == b"application/json"
    assert pyjson.loads(body) == {"ok": True, "count": 3, "msg": "hi"}, body
    s.close()
    cases = [
        (b'[1, 2, 3]', {"ok": True, "count": 3, "msg": ""}),
        (b'123', {"ok": True, "count": 0, "msg": ""}),
        (b'{"msg": 123}', {"ok": True, "count": 1, "msg": ""}),
        (b'{"a": "x\\ny"}', {"ok": True, "count": 1, "msg": ""}),
    ]
    for payload, want in cases:
        s, f = post(port, "/api/dom", payload)
        code, _, _, _, body = read_response(f)
        assert code == 200 and pyjson.loads(body) == want, (payload, code, body)
        s.close()
    for payload in (b'{"a": }', b'', b'{"a": 1} x', b'{oops}'):
        s, f = post(port, "/api/dom", payload)
        code, _, _, _, body = read_response(f)
        assert code == 400 and body == b"Bad Request", (payload, code, body)
        s.close()
    print("  [PASS] test_07_dom_json")


def test_08_keepalive_split_pipeline(port):
    # (a) Sequential keep-alive mix on one connection.
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    f = s.makefile("rb")
    s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n")
    code, _, _, _, body = read_response(f)
    assert (code, body) == (200, b"Hello, World!"), (code, body)
    s.sendall(b"GET /users/5 HTTP/1.1\r\nHost: localhost\r\n\r\n")
    code, _, _, _, body = read_response(f)
    assert code == 200 and pyjson.loads(body)["id"] == "5", (code, body)
    payload = b'{"name": "ka", "age": 9}'
    s.sendall(b"POST /api/typed HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n" % len(payload) + payload)
    code, _, _, _, body = read_response(f)
    assert code == 200 and pyjson.loads(body)["name"] == "ka", (code, body)
    # (b) Split-recv across a JSON POST body (mid-escape split).
    payload = b'{"name": "sp\\"lit", "age": 11, "tags": ["t1", "t2"]}'
    hdr = b"POST /api/typed HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n" % len(payload)
    cut = 13  # inside the escaped quote of "sp\"lit"
    s.sendall(hdr + payload[:cut])
    time.sleep(0.05)
    s.sendall(payload[cut:cut + 20])
    time.sleep(0.05)
    s.sendall(payload[cut + 20:])
    code, _, _, _, body = read_response(f)
    got = pyjson.loads(body)
    assert code == 200 and got["name"] == 'sp"lit' and got["tags"] == 2, (code, body)
    s.close()
    # (c) Pipelined mix in a single packet: GET + POST JSON + param + malformed.
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    f = s.makefile("rb")
    p1 = b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n"
    pj = b'{"name": "pipe", "age": 3}'
    p2 = b"POST /api/typed HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n" % len(pj) + pj
    p3 = b"GET /users/7 HTTP/1.1\r\nHost: localhost\r\n\r\n"
    pb = b'{"name": "bad"'
    p4 = b"POST /api/typed HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n" % len(pb) + pb
    s.sendall(p1 + p2 + p3 + p4)
    code1, _, _, _, body1 = read_response(f)
    code2, _, _, _, body2 = read_response(f)
    code3, _, _, _, body3 = read_response(f)
    code4, _, _, _, body4 = read_response(f)
    assert (code1, body1) == (200, b"Hello, World!"), (code1, body1)
    assert code2 == 200 and pyjson.loads(body2)["name"] == "pipe", (code2, body2)
    assert code3 == 200 and pyjson.loads(body3)["id"] == "7", (code3, body3)
    assert (code4, body4) == (400, b"Bad Request"), (code4, body4)
    # Still alive: per-request scopes neither leaked nor clobbered.
    s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    code5, _, _, _, body5 = read_response(f)
    assert (code5, body5) == (200, b"Hello, World!"), (code5, body5)
    s.close()
    # (d) 20x pipelined GET /json: identical bodies prove no cross-talk.
    s = socket.create_connection(("127.0.0.1", port), timeout=10.0)
    f = s.makefile("rb")
    s.sendall(b"GET /json HTTP/1.1\r\nHost: localhost\r\n\r\n" * 20)
    bodies = set()
    for _ in range(20):
        code, _, _, _, body = read_response(f)
        assert code == 200, code
        bodies.add(body)
    assert len(bodies) == 1, f"pipelined bodies diverged: {len(bodies)}"
    want = pyjson.loads(bodies.pop())
    assert want["message"] == "Hello, World!" and want["user"]["id"] == 42, want
    s.close()
    print("  [PASS] test_08_keepalive_split_pipeline")


def test_09_stats_and_large(port):
    s, f, _ = get(port, "/stats")
    code, _, _, _, body = read_response(f)
    assert code == 200, code
    stats = dict(p.split("=") for p in body.decode().split())
    for key in ("worker", "active", "accepted", "rejected", "timed_out", "tx_queued"):
        assert key in stats, stats
    assert int(stats["accepted"]) >= 1, stats
    s.close()
    s, f, _ = get(port, "/large")
    code, _, _, _, body = read_response(f)
    assert code == 200 and len(body) == 16384, (code, len(body))
    assert body == b"0123456789ABCDEF" * 1024, body[:32]
    s.close()
    print("  [PASS] test_09_stats_and_large")


def wait_for_port(port, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError(f"Port {port} not ready")


def check_no_sanitizer_errors(stderr_path, label):
    with open(stderr_path, "rb") as fh:
        err = fh.read()
    markers = (b"AddressSanitizer", b"runtime error:", b"LeakSanitizer",
               b"UndefinedBehaviorSanitizer", b"SUMMARY:")
    hits = [m for m in markers if m in err]
    assert not hits, f"[{label}] sanitizer output in {stderr_path}: {err[-2000:]!r}"


def test_10_two_workers(server_bin, port, label):
    err_path = f"/tmp/p2_{label}_w2_stderr.txt"
    with open(err_path, "wb") as err_fh:
        proc = subprocess.Popen([server_bin, str(port), "30000", "10000", "2"],
                                stdout=subprocess.PIPE, stderr=err_fh)
        try:
            proc.stdout.readline()
            wait_for_port(port)
            # CPU affinity: workers pinned to CPUs 0 and 2 (physical cores 0,1).
            task_dir = f"/proc/{proc.pid}/task"
            affs = set()
            for tid in os.listdir(task_dir):
                try:
                    with open(f"{task_dir}/{tid}/status") as fh:
                        for line in fh:
                            if line.startswith("Cpus_allowed_list:"):
                                affs.add(line.split(":")[1].strip())
                except FileNotFoundError:
                    pass
            assert "0" in affs, affs
            assert "2" in affs, affs
            # 200 mixed connections: params + typed JSON + DOM + plaintext.
            seen_workers = set()
            for i in range(200):
                kind = i % 4
                if kind == 0:
                    s, f, _ = get(port, f"/users/{i}", keepalive=False)
                    code, hdrs, _, _, body = read_response(f)
                    assert code == 200 and pyjson.loads(body)["id"] == str(i), (code, body)
                elif kind == 1:
                    payload = pyjson.dumps({"name": f"w{i}", "age": i}).encode()
                    s, f = post(port, "/api/typed", payload, keepalive=False)
                    code, hdrs, _, _, body = read_response(f)
                    assert code == 200 and pyjson.loads(body)["age"] == i, (code, body)
                elif kind == 2:
                    payload = pyjson.dumps({"msg": f"m{i}", "k": i}).encode()
                    s, f = post(port, "/api/dom", payload, keepalive=False)
                    code, hdrs, _, _, body = read_response(f)
                    assert code == 200 and pyjson.loads(body)["msg"] == f"m{i}", (code, body)
                else:
                    s, f, _ = get(port, "/plaintext", keepalive=False)
                    code, hdrs, _, _, body = read_response(f)
                    assert (code, body) == (200, b"Hello, World!"), (code, body)
                if b"x-worker" in hdrs:
                    seen_workers.add(hdrs[b"x-worker"])
                s.close()
            assert seen_workers == {b"0", b"1"}, seen_workers
            # Clean shutdown of BOTH workers: each __shutdown stops the worker
            # that serves it; repeat until the port closes, then expect exit 0.
            for _ in range(30):
                try:
                    s = socket.create_connection(("127.0.0.1", port), timeout=1.0)
                except OSError:
                    break
                try:
                    s.sendall(b"POST /__shutdown HTTP/1.1\r\nHost: localhost\r\n"
                              b"Content-Length: 0\r\nConnection: close\r\n\r\n")
                    s.recv(256)
                except OSError:
                    pass
                s.close()
                time.sleep(0.2)
            rc = proc.wait(timeout=10)
            assert rc == 0, f"exit code {rc}"
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait()
    check_no_sanitizer_errors(err_path, label + "-w2")
    print("  [PASS] test_10_two_workers (workers 0+1 served, CPU 0+2, exit 0)")


def run_suite(server_bin, base_port, label):
    print(f"=== Running Phase 2 Framework Suite [{label}] ({server_bin}) ===")
    err_path = f"/tmp/p2_{label}_stderr.txt"
    with open(err_path, "wb") as err_fh:
        proc = subprocess.Popen([server_bin, str(base_port), "30000", "10000", "1"],
                                stdout=subprocess.PIPE, stderr=err_fh)
        try:
            proc.stdout.readline()
            wait_for_port(base_port)
            test_01_static_and_byte_shape(base_port)
            test_02_params_query_headers(base_port)
            test_03_404_vs_405(base_port)
            test_04_middleware_auth(base_port)
            test_05_head(base_port)
            test_06_typed_json(base_port)
            test_07_dom_json(base_port)
            test_08_keepalive_split_pipeline(base_port)
            test_09_stats_and_large(base_port)
            # Graceful shutdown so LSan runs at clean exit.
            s = socket.create_connection(("127.0.0.1", base_port), timeout=2.0)
            s.sendall(b"POST /__shutdown HTTP/1.1\r\nHost: localhost\r\n"
                      b"Content-Length: 0\r\nConnection: close\r\n\r\n")
            s.recv(256)
            s.close()
            rc = proc.wait(timeout=10)
            assert rc == 0, f"exit code {rc}"
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait()
    check_no_sanitizer_errors(err_path, label)
    test_10_two_workers(server_bin, base_port + 50, label)
    print(f"=== ALL 10 PHASE 2 TESTS PASSED [{label}] ===\n")


if __name__ == "__main__":
    binary = sys.argv[1] if len(sys.argv) > 1 else "./src/server_phase2"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 18210
    label = sys.argv[3] if len(sys.argv) > 3 else "Release"
    run_suite(binary, port, label)
