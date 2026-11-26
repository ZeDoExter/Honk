#!/usr/bin/env python3
"""Net suite: dual-stack IPv6, $HONK_BIND, Unix sockets (Release + ASan)."""
import json as pyjson
import os
import signal
import socket
import stat
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_response(f):
    status = f.readline().decode("latin1")
    assert status.startswith("HTTP/1.1 "), f"bad status: {status!r}"
    code = int(status.split(" ")[1])
    hdrs = {}
    while True:
        line = f.readline()
        assert line, "EOF in headers"
        if line in (b"\r\n", b"\n"):
            break
        k, v = line.split(b":", 1)
        hdrs[k.strip().lower()] = v.strip()
    body = b""
    clen = int(hdrs.get(b"content-length", b"0") or 0)
    while len(body) < clen:
        chunk = f.read(clen - len(body))
        assert chunk, "EOF in body"
        body += chunk
    return code, hdrs, body


def wait_for_port(port, host="127.0.0.1", timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError(f"port {port} not ready")


def wait_for_unix(path, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.5)
            s.connect(path)
            s.close()
            return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError(f"unix socket {path} not ready")


def ws_client_frame(opcode, payload):
    out = bytearray([(0x80 | opcode)])
    n = len(payload)
    out.append(0x80 | n)
    mkey = b"\x37\xfa\x21\x3d"
    out.extend(mkey)
    out.extend(bytes(payload[i] ^ mkey[i & 3] for i in range(n)))
    return bytes(out)


def ws_server_frame(f):
    hdr = f.read(2)
    assert len(hdr) == 2
    op = hdr[0] & 0x0F
    assert not (hdr[1] & 0x80)
    n = hdr[1] & 0x7F
    if n == 126:
        n = int.from_bytes(f.read(2), "big")
    elif n == 127:
        n = int.from_bytes(f.read(8), "big")
    return op, f.read(n) if n else b""


def test_dual_stack(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    s.sendall(b"GET /my-ip HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, _, body = read_response(s.makefile("rb"))
    s.close()
    assert code == 200 and body == b"127.0.0.1", (code, body)

    s = socket.create_connection(("::1", port), timeout=5.0)
    s.sendall(b"GET /my-ip HTTP/1.1\r\nHost: [::1]\r\nConnection: close\r\n\r\n")
    code, _, body = read_response(s.makefile("rb"))
    s.close()
    assert code == 200 and body == b"::1", (code, body)

    s = socket.create_connection(("::1", port), timeout=5.0)
    s.sendall(b"GET /ws HTTP/1.1\r\nHost: [::1]\r\nUpgrade: websocket\r\n"
              b"Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
              b"Sec-WebSocket-Version: 13\r\n\r\n")
    f = s.makefile("rb")
    assert f.readline().startswith(b"HTTP/1.1 101")
    while f.readline() not in (b"\r\n", b"\n", b""):
        pass
    s.sendall(ws_client_frame(1, "v6-echo".encode()))
    op, echo = ws_server_frame(f)
    assert op == 1 and echo == b"v6-echo", (op, echo)
    s.close()
    print("  [PASS] test_dual_stack")


def test_honk_bind(server_bin, port, label):
    env = dict(os.environ, HONK_BIND="127.0.0.1")
    err_path = f"/tmp/honknet_{label}_bind_stderr.txt"
    with open(err_path, "wb") as err_fh:
        proc = subprocess.Popen([server_bin, str(port)], stdout=subprocess.PIPE,
                                stderr=err_fh, cwd=ROOT, env=env)
        try:
            proc.stdout.readline()
            wait_for_port(port)
            s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
            s.sendall(b"GET /my-ip HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            code, _, body = read_response(s.makefile("rb"))
            s.close()
            assert code == 200 and body == b"127.0.0.1", (code, body)
            try:
                socket.create_connection(("::1", port), timeout=2.0).close()
                raise AssertionError("::1 must refuse on a 127.0.0.1-only bind")
            except OSError:
                pass
            proc.terminate()
            assert proc.wait(timeout=10) == 0
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    with open(err_path, "rb") as fh:
        err = fh.read()
    for m in (b"AddressSanitizer", b"runtime error:", b"LeakSanitizer", b"SUMMARY:"):
        assert m not in err, f"[{label}-bind] sanitizer hit: {err[-1500:]!r}"
    print("  [PASS] test_honk_bind")


def req_unix(path, payload, timeout=5.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(path)
    s.sendall(payload)
    return s, s.makefile("rb")


def test_unix(server_bin, label, workers):
    path = f"/tmp/honk_net_{label}_w{workers}.sock"
    try:
        os.unlink(path)
    except OSError:
        pass
    args = [server_bin, f"unix:{path}"]
    if workers > 1:
        args.append(str(workers))
    err_path = f"/tmp/honknet_{label}_w{workers}_stderr.txt"
    with open(err_path, "wb") as err_fh:
        proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=err_fh, cwd=ROOT)
        try:
            proc.stdout.readline()
            wait_for_unix(path)
            st = os.stat(path)
            assert stat.S_ISSOCK(st.st_mode), "socket file missing"
            assert stat.S_IMODE(st.st_mode) == 0o660, oct(stat.S_IMODE(st.st_mode))
            for _ in range(2 + (2 if workers > 1 else 0)):
                s, f = req_unix(path, b"GET /my-ip HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                code, _, body = read_response(f)
                s.close()
                assert code == 200 and body == b"unix", (code, body)
            if workers > 1:
                # Shared pre-fork listener: prove BOTH workers accept. Unix
                # sockets have no REUSEPORT balancing, so rapid conns stick to
                # whoever is hot; STOP the child to force parent-side accept.
                kids = subprocess.run(["pgrep", "-P", str(proc.pid)],
                                        capture_output=True, text=True)
                child = int(kids.stdout.strip().split()[0])
                os.kill(child, signal.SIGSTOP)
                try:
                    for _ in range(3):
                        s, f = req_unix(path, b"GET /wid HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                        code, _, body = read_response(f)
                        s.close()
                        assert code == 200 and pyjson.loads(body) == {"worker": 0}, body
                finally:
                    os.kill(child, signal.SIGCONT)
            proc.terminate()
            assert proc.wait(timeout=10) == 0
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    assert not os.path.exists(path), "socket path must be unlinked on shutdown"
    with open(err_path, "rb") as fh:
        err = fh.read()
    for m in (b"AddressSanitizer", b"runtime error:", b"LeakSanitizer", b"SUMMARY:"):
        assert m not in err, f"[{label}-w{workers}] sanitizer hit: {err[-1500:]!r}"
    print(f"  [PASS] test_unix (workers={workers})")


def run_suite(server_bin, port, label):
    print(f"=== Running Net Suite [{label}] ({server_bin}) ===")
    err_path = f"/tmp/honknet_{label}_stderr.txt"
    with open(err_path, "wb") as err_fh:
        proc = subprocess.Popen([server_bin, str(port)], stdout=subprocess.PIPE,
                                stderr=err_fh, cwd=ROOT)
        try:
            proc.stdout.readline()
            wait_for_port(port)
            test_dual_stack(port)
            s = socket.create_connection(("127.0.0.1", port), timeout=2.0)
            s.sendall(b"POST /__shutdown HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            s.recv(256)
            s.close()
            assert proc.wait(timeout=10) == 0, "exit code"
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait()
    with open(err_path, "rb") as fh:
        err = fh.read()
    for m in (b"AddressSanitizer", b"runtime error:", b"LeakSanitizer", b"SUMMARY:"):
        assert m not in err, f"[{label}] sanitizer hit: {err[-1500:]!r}"
    test_honk_bind(server_bin, port + 10, label)
    test_unix(server_bin, label, 1)
    test_unix(server_bin, label, 2)
    print(f"=== ALL 4 NET TESTS PASSED [{label}] ===\n")


if __name__ == "__main__":
    binary = sys.argv[1] if len(sys.argv) > 1 else "./test/app_net"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 18470
    label = sys.argv[3] if len(sys.argv) > 3 else "Release"
    run_suite(binary, port, label)
