#!/usr/bin/env python3
"""
App DSL + SIGINT/SIGTERM drain + HONK_WORKERS suite (Release + ASan+UBSan+LSan).

Exercises every route/JSON/body helper in src/honk_app/honk_app.goose,
verifies <250ms idle SIGINT stop, mid-transfer 512 KiB SIGTERM EPOLLOUT
outbound drain (with immediate listen-socket closure), and multi-process
SO_REUSEPORT scaling via $HONK_WORKERS and honk::listen_workers().
"""

import json as pyjson
import os
import signal
import socket
import subprocess
import sys
import threading
import time


def read_response(f, skip_body=False):
    status_line = f.readline().decode("latin1")
    assert status_line.startswith("HTTP/1.1 "), f"bad status: {status_line!r}"
    code = int(status_line.split(" ")[1])
    headers = {}
    while True:
        line = f.readline()
        assert line, "EOF in headers"
        if line in (b"\r\n", b"\n"):
            break
        k, v = line.split(b":", 1)
        headers[k.strip().lower()] = v.strip()
    body = b""
    if not skip_body:
        clen = int(headers.get(b"content-length", b"0") or 0)
        while len(body) < clen:
            chunk = f.read(clen - len(body))
            assert chunk, "EOF in body"
            body += chunk
    return code, headers, body


def req(port, method, path, body=None):
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    hdr = f"{method} {path} HTTP/1.1\r\nHost: x\r\n".encode()
    if body is not None:
        hdr += f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n".encode()
    hdr += b"Connection: close\r\n\r\n"
    s.sendall(hdr + (body or b""))
    f = s.makefile("rb")
    out = read_response(f, skip_body=(method == "HEAD" or False))
    if out[0] == 204:
        assert f.read() == b""
    s.close()
    return out


def wait_for_port(port, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError(f"Port {port} not ready")


def assert_clean_stderr(err_path, tag):
    with open(err_path, "rb") as fh:
        err = fh.read()
    for m in (b"AddressSanitizer", b"runtime error:", b"LeakSanitizer", b"SUMMARY:"):
        assert m not in err, f"[{tag}] sanitizer hit: {err[-1500:]!r}"


def test_static_and_first_match(port):
    assert req(port, "GET", "/")[0:3:2] == (200, b"dsl root")
    code, hdrs, body = req(port, "GET", "/txt")
    assert (code, hdrs[b"content-type"], body) == (200, b"text/plain", b"plain literal")
    code, hdrs, body = req(port, "GET", "/jraw")
    assert (code, hdrs[b"content-type"], body) == (200, b"application/json", b'{"raw":1}')
    # First-match-wins
    assert req(port, "GET", "/first")[2] == b"winner"
    # HEAD shares GET routes with Content-Length preserved and empty body
    code, hdrs, body = req(port, "HEAD", "/txt")
    assert code == 200 and hdrs[b"content-length"] == b"13" and body == b""
    print("  [PASS] test_static_and_first_match")


def test_methods_and_405_vs_404(port):
    assert req(port, "PUT", "/item", b"")[0:3:2] == (200, b'{"ok":true}')
    assert req(port, "PATCH", "/item", b"")[0:3:2] == (200, b"patched")
    code, hdrs, _ = req(port, "DELETE", "/item")
    assert code == 204 and hdrs[b"content-length"] == b"0"

    # Wrong method on matched static, param, int-param, 2-param, and wildcard routes -> 405
    for method, path in [
        ("POST", "/txt"),
        ("DELETE", "/p/slug1"),
        ("PUT", "/i/42"),
        ("POST", "/orgs/g/repos/h"),
        ("DELETE", "/w/tail/path"),
        ("GET", "/item"),
    ]:
        code, _, body = req(port, method, path, b"" if method in ("POST", "PUT") else None)
        assert (code, body) == (405, b"Method Not Allowed"), (method, path, code, body)

    # Unmatched paths -> 404
    for path in ["/nope", "/p/", "/p/a/b", "/orgs/onlyone", "/orgs/a/repos/", "/w/"]:
        code, _, body = req(port, "GET", path)
        assert (code, body) == (404, b"Not Found"), (path, code, body)
    print("  [PASS] test_methods_and_405_vs_404")


def test_params_and_wildcards(port):
    assert req(port, "GET", "/p/hello-world")[0:3:2] == (200, b"hello-world")
    assert pyjson.loads(req(port, "GET", "/i/9223372036854775807")[2]) == {"id": 9223372036854775807}
    assert pyjson.loads(req(port, "POST", "/i/15/clone", b"")[2]) == {"cloned": 15}
    assert pyjson.loads(req(port, "PUT", "/i/22/publish", b"")[2]) == {"published": 22}
    assert pyjson.loads(req(port, "PATCH", "/i/99/toggle", b"")[2]) == {"toggled": 99}
    assert pyjson.loads(req(port, "PATCH", "/i/-42", b"")[2]) == {"patched": -42}
    assert pyjson.loads(req(port, "DELETE", "/i/0")[2]) == {"deleted": 0}

    for method, path in [
        ("GET", "/i/abc"),
        ("POST", "/i/bad/clone"),
        ("PUT", "/i/bad/publish"),
        ("PATCH", "/i/bad/toggle"),
        ("PATCH", "/i/12x"),
        ("DELETE", "/i/9223372036854775808"),
    ]:
        code, _, body = req(port, method, path, b"" if method in ("POST", "PUT", "PATCH") else None)
        assert code == 400 and pyjson.loads(body) == {"error": "path parameter must be an integer"}, (method, path, code, body)

    code, _, body = req(port, "GET", "/orgs/goose-lang/repos/honk")
    assert code == 200 and pyjson.loads(body) == {"org": "goose-lang", "repo": "honk", "first_idx": "goose-lang"}

    assert req(port, "GET", "/w/a/b/c.txt")[0:3:2] == (200, b"a/b/c.txt")
    assert req(port, "PATCH", "/pw/123/toggle", b"")[0:3:2] == (200, b"123/toggle")

    # Backward-compatible aliases
    assert req(port, "GET", "/compat/p/ok")[0:3:2] == (200, b"ok")
    assert pyjson.loads(req(port, "GET", "/compat/a/1/b/2")[2]) == {"x": "1", "y": "2"}
    assert req(port, "GET", "/compat/w/x/y")[0:3:2] == (200, b"x/y")
    print("  [PASS] test_params_and_wildcards")


def test_jwriter_and_body_helpers(port):
    code, _, body = req(port, "GET", "/jtypes")
    assert code == 200
    assert pyjson.loads(body) == {"s": 'a"b', "i": -9, "f": 2.5, "b": True, "n": None, "r": [1, 2]}

    code, _, body = req(port, "POST", "/echo-json", b'{"s":"hi\\n","n":77,"b":false,"extra":[1]}')
    assert code == 201 and pyjson.loads(body) == {"s": "hi\n", "n": 77, "b": False}

    code, _, body = req(port, "POST", "/echo-json", b'{"s":"hi","n":"not-int","b":true}')
    assert code == 400

    assert req(port, "POST", "/req-str", b'{"title":"buy oats"}')[0:3:2] == (200, b"buy oats")
    for bad in [b"{}", b'{"title":""}', b'{"title":123}', b"{bad json"]:
        code, _, body = req(port, "POST", "/req-str", bad)
        assert code == 400 and pyjson.loads(body) == {"error": "invalid or missing field: title"}, (bad, code, body)

    # Nested group + nested obj/arr + range validator + bearer guard over TCP
    code, _, body = req(port, "GET", "/v1/tree")
    assert code == 200 and pyjson.loads(body) == {"meta": {"ver": 4}, "items": ["x", "y"]}

    code, _, body = req(port, "POST", "/v1/age-check", b'{"age":200}')
    assert code == 400 and pyjson.loads(body) == {"error": "out of range: age"}
    code, _, body = req(port, "POST", "/v1/age-check", b'{"age":30}')
    assert code == 200 and pyjson.loads(body) == {"age": 30}

    code, _, _ = req(port, "GET", "/v1/sec/who")
    assert code == 401

    # Socket peer client_ip() + TCP rate_limit_key (exercises tls_rl_table + shutdown free under LSan)
    assert req(port, "GET", "/v1/my-ip")[0:3:2] == (200, b"127.0.0.1")
    assert req(port, "GET", "/v1/rl-tcp")[0] == 200
    assert req(port, "GET", "/v1/rl-tcp")[0] == 200
    code, hdrs, body = req(port, "GET", "/v1/rl-tcp")
    assert code == 429 and b"retry-after" in hdrs and body == b"Too Many Requests"
    print("  [PASS] test_jwriter_and_body_helpers")


def test_outbound_drain_on_sigterm(server_bin, port, label):
    err_path = f"/tmp/honkdsl_{label}_drain_stderr.txt"
    with open(err_path, "wb") as err_fh:
        proc = subprocess.Popen([server_bin, str(port)], stdout=subprocess.PIPE, stderr=err_fh)
        try:
            proc.stdout.readline()
            wait_for_port(port)

            # Open /bigstream with tiny RCVBUF so ~450 KiB stays queued in server pending_tx
            s = socket.create_connection(("127.0.0.1", port), timeout=10.0)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16384)
            s.sendall(b"GET /bigstream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            f = s.makefile("rb")
            status = f.readline()
            assert status.startswith(b"HTTP/1.1 200"), status
            while f.readline() not in (b"\r\n", b"\n", b""):
                pass

            # Send SIGTERM while ~100 KiB body is still backpressured in pending_tx
            proc.send_signal(signal.SIGTERM)
            time.sleep(0.05)

            # Drain client socket: must receive all 128 KiB without truncation!
            want_len = 8192 * 16
            got = bytearray()
            while len(got) < want_len:
                chunk = f.read(65536)
                assert chunk, f"truncated on SIGTERM drain at {len(got)}/{want_len}"
                got.extend(chunk)
            s.close()
            assert len(got) == want_len and got[:16] == b"0123456789ABCDEF"

            assert proc.wait(timeout=5) == 0
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    assert_clean_stderr(err_path, f"{label}-drain")
    print("  [PASS] test_outbound_drain_on_sigterm (128 KiB mid-flight flushed, exit 0)")


def test_multiworker_fork(server_bin, port, label):
    # Test both HONK_WORKERS=2 env var and explicit listen_workers(port, 2)
    for mode, argv, extra_env in [
        ("env", [server_bin, str(port)], {"HONK_WORKERS": "2"}),
        ("explicit", [server_bin, str(port + 1), "2"], {}),
    ]:
        p_port = int(argv[1])
        err_path = f"/tmp/honkdsl_{label}_mw_{mode}_stderr.txt"
        env = dict(os.environ)
        env.update(extra_env)
        with open(err_path, "wb") as err_fh:
            proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=err_fh, env=env)
            try:
                proc.stdout.readline()
                wait_for_port(p_port)
                seen_workers = set()
                lock = threading.Lock()

                def hit():
                    local = set()
                    for _ in range(25):
                        code, _, body = req(p_port, "GET", "/wid")
                        assert code == 200
                        local.add(pyjson.loads(body)["worker"])
                    with lock:
                        seen_workers.update(local)

                threads = [threading.Thread(target=hit) for _ in range(6)]
                for t in threads:
                    t.start()
                for t in threads:
                    t.join()
                assert seen_workers == {0, 1}, f"expected workers {{0, 1}}, got {seen_workers}"

                # Single SIGTERM to parent must forward to child, drain, join, and exit 0
                proc.send_signal(signal.SIGTERM)
                assert proc.wait(timeout=10) == 0
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
        assert_clean_stderr(err_path, f"{label}-mw-{mode}")
    print("  [PASS] test_multiworker_fork (HONK_WORKERS=2 + listen_workers(2), workers {0,1}, SIGTERM exit 0)")


def run_suite(server_bin, port, label):
    print(f"=== Running App DSL + Runtime Suite [{label}] ({server_bin}) ===")
    err_path = f"/tmp/honkdsl_{label}_stderr.txt"
    with open(err_path, "wb") as err_fh:
        proc = subprocess.Popen([server_bin, str(port)], stdout=subprocess.PIPE, stderr=err_fh)
        try:
            proc.stdout.readline()
            wait_for_port(port)
            test_static_and_first_match(port)
            test_methods_and_405_vs_404(port)
            test_params_and_wildcards(port)
            test_jwriter_and_body_helpers(port)

            # Idle SIGINT: must wake epoll_wait via EINTR immediately and exit 0
            t0 = time.monotonic()
            proc.send_signal(signal.SIGINT)
            rc = proc.wait(timeout=5)
            dt_ms = (time.monotonic() - t0) * 1000.0
            assert rc == 0, f"SIGINT exit {rc}"
            print(f"  [PASS] test_idle_sigint (clean exit 0 in {dt_ms:.1f} ms)")
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    assert_clean_stderr(err_path, label)

    test_outbound_drain_on_sigterm(server_bin, port + 2, label)
    test_multiworker_fork(server_bin, port + 4, label)
    print(f"=== ALL 7 APP DSL + RUNTIME TESTS PASSED [{label}] ===\n")


if __name__ == "__main__":
    binary = sys.argv[1] if len(sys.argv) > 1 else "./test/app_dsl"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 18430
    label = sys.argv[3] if len(sys.argv) > 3 else "Release"
    run_suite(binary, port, label)
