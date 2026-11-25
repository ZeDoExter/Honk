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


def read_chunked_response(f, skip_body=False):
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
    assert b"content-length" not in headers, f"RFC 9112 violation: {headers}"
    assert headers.get(b"transfer-encoding") == b"chunked", headers
    out = bytearray()
    if not skip_body:
        while True:
            sz_line = f.readline().strip()
            sz = int(sz_line, 16)
            if sz == 0:
                assert f.readline() == b"\r\n"
                break
            data = f.read(sz)
            assert len(data) == sz
            assert f.read(2) == b"\r\n"
            out.extend(data)
    return code, headers, bytes(out)


def test_streaming_sse_chunked_and_forms(port):
    # 1. Live TCP chunked stream + SSE + HEAD /v1/sse + keep-alive reuse on the same socket!
    with socket.create_connection(("127.0.0.1", port), timeout=5.0) as s:
        f = s.makefile("rb")
        s.sendall(b"GET /v1/stream HTTP/1.1\r\nHost: x\r\n\r\n")
        c1, h1, b1 = read_chunked_response(f)
        assert (c1, h1[b"content-type"], b1) == (200, b"text/plain", b"chunk-one\nchunk-two\n")

        s.sendall(b"GET /v1/sse HTTP/1.1\r\nHost: x\r\n\r\n")
        c2, h2, b2 = read_chunked_response(f)
        assert c2 == 200 and h2[b"content-type"] == b"text/event-stream" and h2[b"cache-control"] == b"no-cache"
        assert b2 == b'retry: 2000\n\ndata: hi\ndata: there\n\nevent: upd\ndata: {"k":1}\n\n', b2

        # HEAD on SSE route: headers emitted, zero body bytes, connection stays usable!
        s.sendall(b"HEAD /v1/sse HTTP/1.1\r\nHost: x\r\n\r\n")
        c3, _, b3 = read_chunked_response(f, skip_body=True)
        assert c3 == 200 and b3 == b""

        s.sendall(b"GET /txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        c4, _, b4 = read_response(f)
        assert (c4, b4) == (200, b"plain literal")
        f.close()

    # 2. Inbound Transfer-Encoding: chunked JSON POST to /echo-json
    with socket.create_connection(("127.0.0.1", port), timeout=5.0) as s:
        j_part1 = b'{"s":"chunk'
        j_part2 = b'-ok","n":12,"b":true}'
        wire = (
            b"POST /echo-json HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
            b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            + f"{len(j_part1):x}\r\n".encode() + j_part1 + b"\r\n"
            + f"{len(j_part2):x}\r\n".encode() + j_part2 + b"\r\n0\r\n\r\n"
        )
        s.sendall(wire)
        f = s.makefile("rb")
        code, _, body = read_response(f)
        f.close()
        assert code == 201 and pyjson.loads(body) == {"s": "chunk-ok", "n": 12, "b": True}

    # 3. URL-encoded form + binary multipart/form-data upload over TCP
    with socket.create_connection(("127.0.0.1", port), timeout=5.0) as s:
        form_b = b"msg=Hello+World%21&other=1"
        s.sendall(
            b"POST /v1/form HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\n"
            + f"Content-Length: {len(form_b)}\r\nConnection: close\r\n\r\n".encode() + form_b
        )
        f = s.makefile("rb")
        code, _, body = read_response(f)
        f.close()
        assert (code, body) == (200, b"Hello World!")

    with socket.create_connection(("127.0.0.1", port), timeout=5.0) as s:
        raw_bin = b"\x00\x01PDF-DATA\xff\r\n"
        mp = (
            b"------HonkBnd\r\n"
            b'Content-Disposition: form-data; name="tag"\r\n\r\ninvoice\r\n'
            b"------HonkBnd\r\n"
            b'Content-Disposition: form-data; name="doc"; filename="../../report.pdf"\r\n'
            b"Content-Type: application/pdf\r\n\r\n"
            + raw_bin
            + b"\r\n------HonkBnd--\r\n"
        )
        s.sendall(
            b"POST /v1/upload HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=----HonkBnd\r\n"
            + f"Content-Length: {len(mp)}\r\nConnection: close\r\n\r\n".encode() + mp
        )
        f = s.makefile("rb")
        code, _, body = read_response(f)
        f.close()
        assert code == 200 and pyjson.loads(body) == {"name": "report.pdf", "len": len(raw_bin), "tag": "invoice"}
    print("  [PASS] test_streaming_sse_chunked_and_forms")


def make_ws_client_frame(opcode: int, payload: bytes, fin: bool = True, masked: bool = True) -> bytes:
    b0 = (0x80 if fin else 0x00) | (opcode & 0x0F)
    mask_bit = 0x80 if masked else 0x00
    n = len(payload)
    out = bytearray([b0])
    if n < 126:
        out.append(mask_bit | n)
    elif n <= 65535:
        out.append(mask_bit | 126)
        out.extend(n.to_bytes(2, "big"))
    else:
        out.append(mask_bit | 127)
        out.extend(n.to_bytes(8, "big"))
    if masked:
        mkey = b"\x37\xfa\x21\x3d"
        out.extend(mkey)
        out.extend(bytes(payload[i] ^ mkey[i & 3] for i in range(n)))
    else:
        out.extend(payload)
    return bytes(out)


def read_ws_server_frame(f):
    hdr = f.read(2)
    assert len(hdr) == 2, f"EOF reading ws frame header: {hdr!r}"
    fin = bool(hdr[0] & 0x80)
    opcode = hdr[0] & 0x0F
    masked = bool(hdr[1] & 0x80)
    assert not masked, "Server-to-client WebSocket frame must not be masked"
    n = hdr[1] & 0x7F
    if n == 126:
        n = int.from_bytes(f.read(2), "big")
    elif n == 127:
        n = int.from_bytes(f.read(8), "big")
    payload = f.read(n) if n > 0 else b""
    assert len(payload) == n
    return fin, opcode, payload


def test_websocket_and_openapi(port):
    # 1. OpenAPI 3.1.0 JSON (merges duplicate /todos paths + typed integer :id + bearerAuth) & /v1/docs HTML
    code, hdrs, body = req(port, "GET", "/v1/openapi.json")
    assert code == 200 and hdrs[b"content-type"] == b"application/json"
    spec = pyjson.loads(body)
    assert spec["openapi"] == "3.1.0" and spec["info"]["version"] == "0.7.0"
    assert set(spec["paths"]["/todos"].keys()) == {"get", "post"}
    assert spec["paths"]["/todos/{id}/toggle"]["patch"]["parameters"][0]["schema"]["type"] == "integer"
    assert spec["paths"]["/todos/{id}"]["delete"]["security"] == [{"bearerAuth": []}]
    assert "bearerAuth" in spec["components"]["securitySchemes"]

    code_d, hdrs_d, body_d = req(port, "GET", "/v1/docs")
    assert code_d == 200 and hdrs_d[b"content-type"] == b"text/html" and b"@scalar/api-reference" in body_d

    # 2. Live TCP RFC 6455 WebSocket upgrade + Ping/Pong + fragmented text + 16-bit extended len + Close
    with socket.create_connection(("127.0.0.1", port), timeout=5.0) as s:
        s.sendall(
            b"GET /v1/ws/lobby HTTP/1.1\r\nHost: localhost\r\n"
            b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        f = s.makefile("rb")
        status = f.readline()
        assert status.startswith(b"HTTP/1.1 101 Switching Protocols"), status
        resp_h = {}
        while True:
            ln = f.readline()
            if ln in (b"\r\n", b"\n", b""):
                break
            k, v = ln.split(b":", 1)
            resp_h[k.strip().lower()] = v.strip()
        assert resp_h[b"sec-websocket-accept"] == b"s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

        # Ping -> automatic Pong
        s.sendall(make_ws_client_frame(9, b"hb"))
        fin, op, p_data = read_ws_server_frame(f)
        assert (fin, op, p_data) == (True, 10, b"hb")

        # Fragmented text message (FIN=0 opcode=1 + FIN=1 opcode=0)
        s.sendall(make_ws_client_frame(1, b"hello ", fin=False) + make_ws_client_frame(0, b"ws!", fin=True))
        fin, op, msg1 = read_ws_server_frame(f)
        assert fin and op == 1 and pyjson.loads(msg1) == {"room": "lobby", "msg": "hello ws!"}

        # 200-byte 16-bit extended-length message
        big_txt = "X" * 200
        s.sendall(make_ws_client_frame(1, big_txt.encode()))
        fin, op, msg2 = read_ws_server_frame(f)
        assert fin and op == 1 and pyjson.loads(msg2) == {"room": "lobby", "msg": big_txt}

        # Unmasked client frame -> RFC 6455 §5.1 protocol error Close 1002
        s.sendall(make_ws_client_frame(1, b"unmasked", masked=False))
        fin, op, close_pl = read_ws_server_frame(f)
        assert fin and op == 8 and int.from_bytes(close_pl[:2], "big") == 1002
        f.close()
    # 3. Invalid UTF-8 text frame -> Close 1007; valid multi-byte UTF-8 echoes fine
    with socket.create_connection(("127.0.0.1", port), timeout=5.0) as s:
        s.sendall(
            b"GET /v1/ws/lobby HTTP/1.1\r\nHost: localhost\r\n"
            b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        f = s.makefile("rb")
        assert f.readline().startswith(b"HTTP/1.1 101")
        while f.readline() not in (b"\r\n", b"\n", b""):
            pass
        s.sendall(make_ws_client_frame(1, "héllo".encode()))
        fin, op, msg_ok = read_ws_server_frame(f)
        assert fin and op == 1 and pyjson.loads(msg_ok) == {"room": "lobby", "msg": "héllo"}
        s.sendall(make_ws_client_frame(1, b"\xff\xfe"))
        fin, op, close_utf = read_ws_server_frame(f)
        assert fin and op == 8 and int.from_bytes(close_utf[:2], "big") == 1007
        f.close()
    print("  [PASS] test_websocket_and_openapi")


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
            test_streaming_sse_chunked_and_forms(port)
            test_websocket_and_openapi(port)

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
    print(f"=== ALL 9 APP DSL + RUNTIME TESTS PASSED [{label}] ===\n")


if __name__ == "__main__":
    binary = sys.argv[1] if len(sys.argv) > 1 else "./test/app_dsl"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 18430
    label = sys.argv[3] if len(sys.argv) > 3 else "Release"
    run_suite(binary, port, label)
