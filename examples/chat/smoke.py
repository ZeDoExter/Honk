#!/usr/bin/env python3
"""Chat smoke: login, room fan-out + isolation, history, bad-token 401."""
import json as pyjson
import os
import socket
import subprocess
import sys
import tempfile
import time
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18550


def frame(payload):
    out = bytearray([0x81, 0x80 | len(payload)])
    m = b"\x37\xfa\x21\x3d"
    out.extend(m)
    out.extend(bytes(payload[i] ^ m[i & 3] for i in range(len(payload))))
    return bytes(out)


def read_msg(f):
    h = f.read(2)
    assert len(h) == 2 and (h[0] & 0x0F) == 1
    n = h[1] & 0x7F
    if n == 126:
        n = int.from_bytes(f.read(2), "big")
    return pyjson.loads(f.read(n))


def http(method, target, body=None):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5.0)
    raw = f"{method} {target} HTTP/1.1\r\nHost: x\r\n".encode()
    if body is not None:
        raw += f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n".encode()
    raw += b"Connection: close\r\n\r\n"
    if body is not None:
        raw += body
    s.sendall(raw)
    f = s.makefile("rb")
    code = int(f.readline().split(b" ")[1])
    while f.readline() not in (b"\r\n", b"\n", b""):
        pass
    data = f.read()
    s.close()
    return code, data


def ws_connect(room, token):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5.0)
    s.sendall(f"GET /ws/{room}?token={token} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
              f"Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
              f"Sec-WebSocket-Version: 13\r\n\r\n".encode())
    f = s.makefile("rb")
    return s, f


tmp = tempfile.mkdtemp(prefix="chat_smoke_")
proc = subprocess.Popen([f"{ROOT}/examples/chat/app", str(PORT)],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=tmp)
try:
    proc.stdout.readline()
    time.sleep(0.3)
    code, body = http("POST", "/login", b'{"user":"ada"}')
    assert code == 200, (code, body)
    tok_a = pyjson.loads(body)["token"]
    code, body = http("POST", "/login", b'{"user":"grace"}')
    tok_b = pyjson.loads(body)["token"]
    code, _ = http("POST", "/login", b'{"user":""}')
    assert code == 400, code

    sa, fa = ws_connect("l1", tok_a)
    assert fa.readline().startswith(b"HTTP/1.1 101")
    while fa.readline() not in (b"\r\n", b"\n", b""):
        pass
    sb, fb = ws_connect("l1", tok_b)
    assert fb.readline().startswith(b"HTTP/1.1 101")
    while fb.readline() not in (b"\r\n", b"\n", b""):
        pass
    sc, fc = ws_connect("other", tok_a)
    assert fc.readline().startswith(b"HTTP/1.1 101")
    while fc.readline() not in (b"\r\n", b"\n", b""):
        pass

    sa.sendall(frame(b"first"))
    sb.sendall(frame(b"hey ada"))
    assert read_msg(fa) == {"user": "grace", "text": "hey ada"}
    sc.sendall(frame(b"lonely"))
    sa.sendall(frame(b"hi room"))
    assert read_msg(fb) == {"user": "ada", "text": "hi room"}
    sc.settimeout(0.5)
    try:
        fc.read(2)
        raise AssertionError("room leak: other-room conn got bytes")
    except (socket.timeout, TimeoutError, AssertionError) as e:
        if isinstance(e, AssertionError):
            raise

    code, hist = http("GET", "/history/l1")
    rows = pyjson.loads(hist)
    assert code == 200 and [r["text"] for r in rows] == ["hi room", "hey ada", "first"], hist
    code, hist2 = http("GET", "/history/other")
    assert code == 200 and [r["text"] for r in pyjson.loads(hist2)] == ["lonely"], hist2

    # Heartbeat joins without broadcasting or persisting.
    sd, fd_ = ws_connect("l1", tok_a)
    assert fd_.readline().startswith(b"HTTP/1.1 101")
    while fd_.readline() not in (b"\r\n", b"\n", b""):
        pass
    sd.sendall(frame(b'{"hb":1}'))
    sa.sendall(frame(b"after-hb"))
    assert read_msg(fb) == {"user": "ada", "text": "after-hb"}
    assert read_msg(fd_) == {"user": "ada", "text": "after-hb"}
    code, hist3 = http("GET", "/history/l1")
    assert all(r["text"] != '{"hb":1}' for r in pyjson.loads(hist3)), hist3
    sd.close()

    s_bad, f_bad = ws_connect("l1", "bogus")
    assert f_bad.readline().startswith(b"HTTP/1.1 401"), "bad token must 401"
    s_bad.close()
    print("CHAT SMOKE OK")
finally:
    proc.terminate()
    proc.wait(timeout=10)
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)
