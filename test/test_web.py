#!/usr/bin/env python3
"""
Web-helper suite for the honk::serve API (Release + ASan+UBSan+LSan).

Drives test/helpers_app (param/query/int/decode/bearer/cookie/html/raw/error/
204/redirect/wildcard/CORS/default-404/pipelining) and asserts exact behavior,
clean exit 0, and zero sanitizer findings.
"""

import json as pyjson
import socket
import subprocess
import sys
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


def req(port, payload):
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    s.sendall(payload)
    return s, s.makefile("rb")


def test_params(port):
    s, f = req(port, b"GET /p/str/hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, _, body = read_response(f)
    assert (code, body) == (200, b"hello"), (code, body)
    s.close()
    cases = [
        (b"/p/int/42", 200, b'{"v":42}'),
        (b"/p/int/-7", 200, b'{"v":-7}'),
        (b"/p/int/0", 200, b'{"v":0}'),
        (b"/p/int/9223372036854775807", 200, b'{"v":9223372036854775807}'),
        (b"/p/int/-9223372036854775808", 200, b'{"v":-9223372036854775808}'),
        (b"/p/int/abc", 400, None),
        (b"/p/int/12x", 400, None),
        (b"/p/int/99999999999999999999999", 400, None),
        (b"/p/int/9223372036854775808", 400, None),
        (b"/p/int/-9223372036854775809", 400, None),
        (b"/p/int/3.5", 400, None),
        (b"/p/int/", 404, None),
    ]
    for target, want_code, want_body in cases:
        s, f = req(port, b"GET " + target + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        code, _, body = read_response(f)
        assert code == want_code, (target, code)
        if want_body is not None:
            assert body == want_body, (target, body)
        else:
            assert b"error" in body or body == b"Not Found", (target, body)
        s.close()
    print("  [PASS] test_params")


def test_query_helpers(port):
    cases = [
        (b"/q/or", {b"name": b"anon", "page": 1}),
        (b"/q/or?name=b&page=3", {b"name": b"b", "page": 3}),
        (b"/q/or?page=abc", {b"name": b"anon", "page": 1}),
        (b"/q/or?page=99999999999999999999999", {b"name": b"anon", "page": 1}),
        (b"/q/or?name=&page=-5", {b"name": b"", "page": -5}),
    ]
    for target, want in cases:
        s, f = req(port, b"GET " + target + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        code, hdrs, body = read_response(f)
        assert code == 200, (target, code)
        got = pyjson.loads(body)
        assert got == {"name": want[b"name"].decode(), "page": want["page"]}, (target, got)
        s.close()
    print("  [PASS] test_query_helpers")


def test_decoding(port):
    cases = [
        (b"/q/dec?x=a%20b%2Fc", 200, b"a b/c"),
        (b"/q/dec?x=a+b", 200, b"a b"),
        (b"/q/dec?x=%41%42", 200, b"AB"),
        (b"/q/dec?x=plain", 200, b"plain"),
        (b"/q/dec?x=%zz", 400, b"Bad Request"),
        (b"/q/dec?x=abc%", 400, b"Bad Request"),
        (b"/q/dec?x=%4", 400, b"Bad Request"),
        (b"/q/dec", 400, b"Bad Request"),
        (b"/p/dec/a%20b", 200, b"a b"),
        (b"/p/dec/a+b", 200, b"a+b"),
        (b"/p/dec/%41%42", 200, b"AB"),
        (b"/p/dec/%gg", 400, b"Bad Request"),
    ]
    for target, want_code, want_body in cases:
        s, f = req(port, b"GET " + target + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        code, _, body = read_response(f)
        assert (code, body) == (want_code, want_body), (target, code, body)
        s.close()
    print("  [PASS] test_decoding")


def test_auth_cookies(port):
    cases = [
        (b"Bearer tok123", 200, b"tok123"),
        (b"bearer tok123", 200, b"tok123"),
        (b"BEARER  spaced", 200, b"spaced"),
        (b"Basic xyz", 401, b"Unauthorized"),
        (b"Bearer", 401, b"Unauthorized"),
        (b"Bearer ", 401, b"Unauthorized"),
    ]
    for auth, want_code, want_body in cases:
        s, f = req(port, b"GET /auth/me HTTP/1.1\r\nHost: x\r\nAuthorization: " + auth +
                   b"\r\nConnection: close\r\n\r\n")
        code, _, body = read_response(f)
        assert (code, body) == (want_code, want_body), (auth, code, body)
        s.close()
    s, f = req(port, b"GET /auth/me HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, _, _ = read_response(f)
    assert code == 401, code
    s.close()
    cases = [
        (b"sess=abc123; lang=en", 200, b"abc123"),
        (b"lang=en; sess=xyz", 200, b"xyz"),
        (b"sess = spaced ; x=1", 200, b"spaced"),
        (b"lang=en", 404, b"none"),
    ]
    for ck, want_code, want_body in cases:
        s, f = req(port, b"GET /cookies HTTP/1.1\r\nHost: x\r\nCookie: " + ck +
                   b"\r\nConnection: close\r\n\r\n")
        code, _, body = read_response(f)
        assert (code, body) == (want_code, want_body), (ck, code, body)
        s.close()
    s, f = req(port, b"GET /cookies/set?name=s&val=v HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, hdrs, body = read_response(f)
    assert code == 200 and body == b"set", (code, body)
    assert hdrs[b"set-cookie"] == b"s=v; Path=/; Max-Age=60", hdrs
    s.close()
    print("  [PASS] test_auth_cookies")


def test_responses(port):
    s, f = req(port, b"GET /htmlx HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, hdrs, body = read_response(f)
    assert code == 200 and body == b"<h1>hi</h1>" and hdrs[b"content-type"] == b"text/html", (code, body)
    s.close()
    s, f = req(port, b"GET /rawx HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, hdrs, body = read_response(f)
    assert code == 200 and hdrs[b"content-type"] == b"application/json", (code, hdrs)
    assert pyjson.loads(body) == {"a": [1, 2]}, body
    s.close()
    s, f = req(port, b"GET /errx HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, hdrs, body = read_response(f)
    assert code == 422, code
    assert body == b'{"error":"bad \\"thing\\"\\\\"}', body
    assert pyjson.loads(body) == {"error": 'bad "thing"\\'}, body
    s.close()
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    s.sendall(b"GET /nocont HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    f = s.makefile("rb")
    code, hdrs, _ = read_response(f, skip_body=True)
    assert code == 204 and hdrs[b"content-length"] == b"0", (code, hdrs)
    assert f.read() == b""
    s.close()
    s, f = req(port, b"GET /redir HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, hdrs, body = read_response(f)
    assert code == 302 and hdrs[b"location"] == b"/target" and body == b"", (code, hdrs)
    s.close()
    s, f = req(port, b"GET /redir301 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, hdrs, _ = read_response(f)
    assert code == 301 and hdrs[b"location"] == b"/perm", (code, hdrs)
    s.close()
    print("  [PASS] test_responses")


def test_wildcard_cors_default404(port):
    cases = [
        (b"/files/a/b/c", 200, b"a/b/c"),
        (b"/files/...", 200, b"..."),
        (b"/files/../etc", 400, b"Bad Request"),
        (b"/files/a/../../x", 400, b"Bad Request"),
        (b"/files/..", 400, b"Bad Request"),
        (b"/files/a..b", 200, b"a..b"),
    ]
    for target, want_code, want_body in cases:
        s, f = req(port, b"GET " + target + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        code, _, body = read_response(f)
        assert (code, body) == (want_code, want_body), (target, code, body)
        s.close()
    # Unstaged path -> turn default 404 (proves responded/default path).
    s, f = req(port, b"GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, _, body = read_response(f)
    assert (code, body) == (404, b"Not Found"), (code, body)
    s.close()
    # CORS preflight on any path.
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    s.sendall(b"OPTIONS /users/1 HTTP/1.1\r\nHost: x\r\nOrigin: https://app.example\r\n"
              b"Access-Control-Request-Method: POST\r\nConnection: close\r\n\r\n")
    f = s.makefile("rb")
    code, hdrs, _ = read_response(f, skip_body=True)
    assert code == 204, code
    assert hdrs[b"access-control-allow-origin"] == b"*", hdrs
    assert b"access-control-allow-methods" in hdrs and b"access-control-allow-headers" in hdrs
    assert f.read() == b""
    s.close()
    s, f = req(port, b"GET /cors HTTP/1.1\r\nHost: x\r\nOrigin: https://a.example\r\nConnection: close\r\n\r\n")
    code, hdrs, body = read_response(f)
    assert code == 200 and body == b"cors-ok" and hdrs[b"access-control-allow-origin"] == b"*", (code, hdrs)
    s.close()
    s, f = req(port, b"GET /cors-origin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, hdrs, _ = read_response(f)
    assert hdrs[b"access-control-allow-origin"] == b"https://app.example", hdrs
    s.close()
    print("  [PASS] test_wildcard_cors_default404")


def test_pipeline(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    f = s.makefile("rb")
    s.sendall(b"GET /p/str/a HTTP/1.1\r\nHost: x\r\n\r\n"
              b"GET /q/or?name=z&page=9 HTTP/1.1\r\nHost: x\r\n\r\n"
              b"GET /q/dec?x=%zz HTTP/1.1\r\nHost: x\r\n\r\n")
    c1, _, b1 = read_response(f)
    c2, _, b2 = read_response(f)
    c3, _, b3 = read_response(f)
    assert (c1, b1) == (200, b"a"), (c1, b1)
    assert c2 == 200 and pyjson.loads(b2) == {"name": "z", "page": 9}, (c2, b2)
    assert (c3, b3) == (400, b"Bad Request"), (c3, b3)
    s.sendall(b"GET /cors HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    c4, _, b4 = read_response(f)
    assert (c4, b4) == (200, b"cors-ok"), (c4, b4)
    s.close()
    print("  [PASS] test_pipeline")


def wait_for_port(port, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError(f"Port {port} not ready")


def run_suite(server_bin, port, label):
    print(f"=== Running Web Helper Suite [{label}] ({server_bin}) ===")
    err_path = f"/tmp/honkweb_{label}_stderr.txt"
    with open(err_path, "wb") as err_fh:
        proc = subprocess.Popen([server_bin, str(port)], stdout=subprocess.PIPE, stderr=err_fh)
        try:
            proc.stdout.readline()
            wait_for_port(port)
            test_params(port)
            test_query_helpers(port)
            test_decoding(port)
            test_auth_cookies(port)
            test_responses(port)
            test_wildcard_cors_default404(port)
            test_pipeline(port)
            s = socket.create_connection(("127.0.0.1", port), timeout=2.0)
            s.sendall(b"POST /__shutdown HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            s.recv(256)
            s.close()
            rc = proc.wait(timeout=10)
            assert rc == 0, f"exit code {rc}"
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait()
    with open(err_path, "rb") as fh:
        err = fh.read()
    for m in (b"AddressSanitizer", b"runtime error:", b"LeakSanitizer", b"SUMMARY:"):
        assert m not in err, f"[{label}] sanitizer hit: {err[-1500:]!r}"
    print(f"=== ALL 7 WEB TESTS PASSED [{label}] ===\n")


if __name__ == "__main__":
    binary = sys.argv[1] if len(sys.argv) > 1 else "./test/helpers_app"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 18420
    label = sys.argv[3] if len(sys.argv) > 3 else "Release"
    run_suite(binary, port, label)
