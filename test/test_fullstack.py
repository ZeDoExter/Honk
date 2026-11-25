#!/usr/bin/env python3
"""
Fullstack suite: sendfile static + SQLite (Release + ASan+UBSan+LSan).

Drives test/app_fullstack (static matrix, EAGAIN resume, traversal/security,
CRUD, UTF-8/injection, malformed-JSON discipline, 2-worker WAL, FD-leak)
plus an examples/fullstack_todo end-to-end smoke. Asserts clean exit 0,
zero sanitizer findings, and zero leaked file descriptors.
"""

import hashlib
import json as pyjson
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


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


def req(port, payload, timeout=10.0):
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    s.sendall(payload)
    return s, s.makefile("rb")


def setup_fixtures(tag):
    # Native temp dir (mkdtemp): the repo may sit on a 9P/Windows mount that
    # lacks FIFOs/symlinks/SQLite locking. One process: create, use, delete.
    root = tempfile.mkdtemp(prefix=f"fsroot_{tag}_")
    for name in os.listdir(os.path.join(ROOT, "test", "static_fixtures")):
        src = os.path.join(ROOT, "test", "static_fixtures", name)
        dst = os.path.join(root, name)
        if os.path.isdir(src):
            shutil.copytree(src, dst)
        else:
            shutil.copy2(src, dst)
    big = bytes((i * 2654435761) % 256 for i in range(2 * 1024 * 1024))
    with open(os.path.join(root, "big.bin"), "wb") as f:
        f.write(big)
    os.symlink("/etc/hostname", os.path.join(root, "evil-link"))
    os.mkfifo(os.path.join(root, "myfifo"))
    dbpath = os.path.join(root, "t.db")
    return root, dbpath, hashlib.sha256(big).hexdigest()


def test_static_exact(port, root):
    def fetch(rel):
        with open(os.path.join(root, rel.decode()), "rb") as f:
            return f.read()
    cases = [
        (b"/", b"index.html", b"text/html"),
        (b"/index.html", b"index.html", b"text/html"),
        (b"/app.js", b"app.js", b"text/javascript"),
        (b"/style.css", b"style.css", b"text/css"),
        (b"/data.json", b"data.json", b"application/json"),
        (b"/readme.txt", b"readme.txt", b"text/plain"),
        (b"/sub/", b"sub/index.html", b"text/html"),
    ]
    for target, rel, ctype in cases:
        s, f = req(port, b"GET " + target + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        code, hdrs, body = read_response(f)
        want = fetch(rel)
        assert code == 200, (target, code)
        assert hdrs[b"content-type"] == ctype, (target, hdrs)
        assert hdrs[b"content-length"] == str(len(want)).encode(), (target, hdrs)
        assert body == want, (target, len(body), len(want))
        s.close()
    # No extension / unknown extension -> octet-stream (big.bin).
    s, f = req(port, b"GET /big.bin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, hdrs, body = read_response(f)
    assert code == 200 and hdrs[b"content-type"] == b"application/octet-stream", (code, hdrs)
    assert len(body) == 2 * 1024 * 1024, len(body)
    s.close()
    print("  [PASS] test_static_exact")


def test_static_head(port, root):
    for target, rel in ((b"/app.js", b"app.js"), (b"/", b"index.html")):
        with open(os.path.join(root, rel.decode()), "rb") as f:
            want_len = len(f.read())
        s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
        s.sendall(b"HEAD " + target + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        f = s.makefile("rb")
        code, hdrs, _ = read_response(f, skip_body=True)
        assert code == 200, (target, code)
        assert hdrs[b"content-length"] == str(want_len).encode(), (target, hdrs)
        assert f.read() == b"", target
        s.close()
    print("  [PASS] test_static_head")


def test_static_big_eagain(port, big_sha):
    # Small receive buffer forces partial sendfile + EPOLLOUT resume
    # server-side (2 MiB file >> window). Back-to-back reads: no sleeps.
    s = socket.create_connection(("127.0.0.1", port), timeout=120.0)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32768)
    s.sendall(b"GET /big.bin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    f = s.makefile("rb")
    status = f.readline()
    assert status.startswith(b"HTTP/1.1 200"), status
    hdrs = {}
    while True:
        line = f.readline()
        if line in (b"\r\n", b"\n", b""):
            break
        k, v = line.split(b":", 1)
        hdrs[k.strip().lower()] = v.strip()
    assert hdrs[b"content-length"] == str(2 * 1024 * 1024).encode(), hdrs
    h = hashlib.sha256()
    got = 0
    while got < 2 * 1024 * 1024:
        chunk = f.read(16384)
        assert chunk, "EOF early"
        h.update(chunk)
        got += len(chunk)
    assert h.hexdigest() == big_sha, "big-file bytes mismatch"
    s.close()
    print("  [PASS] test_static_big_eagain")


def test_static_security(port):
    bad = [
        b"/../etc/passwd",
        b"/..%2fetc/passwd",
        b"/%2e%2e%2fetc/passwd",
        b"/%2E%2E/%2E%2E/x",
        b"/a/../../etc/passwd",
        b"/%00",
        b"/a%00b",
        b"/a%5cb",
        b"/%zz",
        b"/abc%",
        b"/evil-link",
        b"/myfifo",
        b"/nope.txt",
        b"/sub",
    ]
    for target in bad:
        s, f = req(port, b"GET " + target + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        code, _, _ = read_response(f)
        assert code == 404, (target, code)
        s.close()
    # Leniency that stays safe: empty segments collapse, "..." is a filename.
    s, f = req(port, b"GET /sub// HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, _, body = read_response(f)
    assert code == 200 and b"sub index" in body, (code, body)
    s.close()
    # Non-GET/HEAD on files -> 405 (missing file + POST -> 405 too: method gate first).
    for method, target in ((b"POST", b"/app.js"), (b"PUT", b"/"), (b"DELETE", b"/nope.txt")):
        s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
        s.sendall(method + b" " + target + b" HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        f = s.makefile("rb")
        code, _, _ = read_response(f)
        assert code == 405, (method, target, code)
        s.close()
    print("  [PASS] test_static_security")


def test_static_pipeline(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    f = s.makefile("rb")
    s.sendall(b"GET /app.js HTTP/1.1\r\nHost: x\r\n\r\n"
              b"GET /style.css HTTP/1.1\r\nHost: x\r\n\r\n")
    c1, _, b1 = read_response(f)
    c2, _, b2 = read_response(f)
    assert (c1, b1) == (200, b'console.log("honk static js");\n'), (c1, b1)
    assert (c2, b2) == (200, b"body{color:#111}\n"), (c2, b2)
    s.sendall(b"GET /data.json HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    c3, _, b3 = read_response(f)
    assert c3 == 200 and pyjson.loads(b3) == {"fixture": True, "n": 42}, (c3, b3)
    s.close()
    print("  [PASS] test_static_pipeline")


def test_db_crud(port):
    def post(body):
        s, f = req(port, b"POST /db HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                         b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
        out = read_response(f)
        s.close()
        return out
    # Empty table -> sql_json yields [].
    s, f = req(port, b"GET /db/all HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, _, body = read_response(f)
    assert code == 200 and body == b"[]", (code, body)
    s.close()
    code, _, body = post(b'{"name":"alice","age":30}')
    assert code == 201, (code, body)
    rid = pyjson.loads(body)["id"]
    s, f = req(port, f"GET /db?id={rid} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
    code, _, body = read_response(f)
    assert code == 200 and pyjson.loads(body) == {"id": rid, "name": "alice", "age": 30}, (code, body)
    s.close()
    # sql_json + sql_json_one_text coverage.
    s, f = req(port, b"GET /db/all HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, _, body = read_response(f)
    assert code == 200 and pyjson.loads(body) == [{"id": rid, "name": "alice", "age": 30}], (code, body)
    s.close()
    s, f = req(port, b"GET /db/by-name?name=alice HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, _, body = read_response(f)
    assert code == 200 and pyjson.loads(body) == {"id": rid, "name": "alice", "age": 30}, (code, body)
    s.close()
    s, f = req(port, b"GET /db/by-name?name=missing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, _, _ = read_response(f)
    assert code == 404, code
    s.close()
    s, f = req(port, b"GET /db/by-name HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, _, _ = read_response(f)
    assert code == 400, code
    s.close()
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    payload = b'{"name":"ally","age":31}'
    s.sendall(f"PUT /db?id={rid} HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
              f"Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n".encode() + payload)
    code, _, body = read_response(s.makefile("rb"))
    assert (code, body) == (200, b'{"ok":true}'), (code, body)
    s.close()
    s, f = req(port, f"GET /db?id={rid} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
    code, _, body = read_response(f)
    assert pyjson.loads(body)["age"] == 31, body
    s.close()
    s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
    s.sendall(f"DELETE /db?id={rid} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
    code, _, _ = read_response(s.makefile("rb"))
    assert code == 200, code
    s.close()
    for method, target, payload, want in (
            ("GET", f"/db?id={rid}", None, 404),
            ("PUT", f"/db?id={rid}", b'{"name":"x","age":1}', 404),
            ("DELETE", f"/db?id={rid}", None, 404),
            ("GET", "/db?id=abc", None, 400),
            ("GET", "/db?id=0", None, 400),
            ("GET", "/db", None, 400),
            ("POST", "/db", b"{oops", 400),
            ("POST", "/db", b'{"name":"","age":1}', 400),
            ("POST", "/db", b'{"age":1}', 400)):
        s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
        hdr = f"{method} {target} HTTP/1.1\r\nHost: x\r\n".encode()
        if payload is not None:
            hdr += b"Content-Type: application/json\r\nContent-Length: %d\r\n" % len(payload)
        hdr += b"Connection: close\r\n\r\n"
        s.sendall(hdr + (payload or b""))
        code, _, _ = read_response(s.makefile("rb"))
        assert code == want, (method, target, payload, code)
        s.close()
    # Statements still healthy after the malformed batch.
    code, _, body = post(b'{"name":"after-bad","age":7,"zzz":[1]}')
    assert code == 201, (code, body)
    print("  [PASS] test_db_crud")


def test_db_strings(port):
    tricky = ["x'; DROP TABLE kv;--", 'q"\\', "%_%", "line\nbreak",
              "caf\u00e9 \u4e2d\u6587 \U0001f600"]
    ids = []
    for name in tricky:
        payload = pyjson.dumps({"name": name, "age": len(name)}).encode()
        s, f = req(port, b"POST /db HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                         b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(payload) + payload)
        code, _, body = read_response(f)
        assert code == 201, (name, code, body)
        ids.append((pyjson.loads(body)["id"], name))
        s.close()
    for rid, name in ids:
        s, f = req(port, f"GET /db?id={rid} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
        code, _, body = read_response(f)
        got = pyjson.loads(body)
        assert code == 200 and got["name"] == name, (rid, got)
        s.close()
        q = urllib.parse.quote(name, safe="")
        s, f = req(port, f"GET /db/by-name?name={q} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
        code, _, body = read_response(f)
        got = pyjson.loads(body)
        assert code == 200 and got == {"id": rid, "name": name, "age": len(name)}, (rid, got)
        s.close()
    s, f = req(port, b"GET /db/all HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    code, _, body = read_response(f)
    all_rows = pyjson.loads(body)
    s.close()
    got_by_id = {r["id"]: r["name"] for r in all_rows}
    for rid, name in ids:
        assert got_by_id.get(rid) == name, (rid, name, got_by_id)
    print("  [PASS] test_db_strings")


def test_db_2workers(server_bin, port, label):
    err_path = f"/tmp/honkfs_{label}_w2_stderr.txt"
    root, dbpath, _ = setup_fixtures(label + "w2")
    with open(err_path, "wb") as err_fh:
        proc = subprocess.Popen([server_bin, str(port), root, "2", dbpath],
                                stdout=subprocess.PIPE, stderr=err_fh, cwd=ROOT)
        try:
            proc.stdout.readline()
            wait_for_port(port)
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
            assert "0" in affs and "2" in affs, affs
            errors = []
            def hammer(n):
                try:
                    for i in range(25):
                        name = f"w{n}-{i}"
                        payload = pyjson.dumps({"name": name, "age": i}).encode()
                        s, f = req(port, b"POST /db HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                                             b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(payload) + payload)
                        code, _, body = read_response(f)
                        s.close()
                        assert code == 201, (code, body)
                        rid = pyjson.loads(body)["id"]
                        s, f = req(port, f"GET /db?id={rid} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
                        code, _, body = read_response(f)
                        s.close()
                        got = pyjson.loads(body)
                        assert code == 200 and got["name"] == name and got["age"] == i, got
                except Exception as e:  # noqa: BLE001 - collected across threads
                    errors.append(e)
            threads = [threading.Thread(target=hammer, args=(n,)) for n in range(8)]
            [t.start() for t in threads]
            [t.join() for t in threads]
            assert not errors, errors[0]
            s = socket.create_connection(("127.0.0.1", port), timeout=2.0)
            s.sendall(b"POST /__shutdown HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            s.recv(256)
            s.close()
            for _ in range(60):
                try:
                    socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
                except OSError:
                    break
                s = socket.create_connection(("127.0.0.1", port), timeout=1.0)
                try:
                    s.sendall(b"POST /__shutdown HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    s.recv(256)
                except OSError:
                    pass
                s.close()
                time.sleep(0.2)
            assert proc.wait(timeout=10) == 0
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait()
            shutil.rmtree(root, ignore_errors=True)
    with open(err_path, "rb") as fh:
        err = fh.read()
    for m in (b"AddressSanitizer", b"runtime error:", b"LeakSanitizer", b"SUMMARY:"):
        assert m not in err, f"[{label}-w2] sanitizer hit: {err[-1500:]!r}"
    print("  [PASS] test_db_2workers (8 threads x 25 POST+GET, CPU 0+2, exit 0)")


def test_fd_leak(port, pid):
    if not os.path.exists("/proc/self/fd"):
        print("  [SKIP] test_fd_leak (no /proc)")
        return
    base = len(os.listdir(f"/proc/{pid}/fd"))
    for _ in range(60):
        s, f = req(port, b"GET /app.js HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        read_response(f)
        s.close()
    for _ in range(60):
        payload = b'{"name":"fd","age":1}'
        s, f = req(port, b"POST /db HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                         b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(payload) + payload)
        read_response(f)
        s.close()
    for _ in range(2):
        s = socket.create_connection(("127.0.0.1", port), timeout=60.0)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32768)
        s.sendall(b"GET /big.bin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        f = s.makefile("rb")
        f.readline()
        while f.readline() not in (b"\r\n", b"\n", b""):
            pass
        while f.read(65536):
            pass
        s.close()
    time.sleep(0.5)
    now = len(os.listdir(f"/proc/{pid}/fd"))
    assert now == base, f"fd leak: {base} -> {now}"
    print(f"  [PASS] test_fd_leak (fds stable at {base})")


def test_fullstack_e2e(label):
    app_dir = os.path.join(ROOT, "examples", "fullstack_todo")
    for suffix in ("", "-wal", "-shm", "-journal"):
        try:
            os.remove(os.path.join(app_dir, "todos.db" + suffix))
        except FileNotFoundError:
            pass
    port = 18449 if label == "Release" else 18459
    app_bin = os.path.join(app_dir, "app_asan" if label != "Release" else "app")
    err_path = f"/tmp/honkfs_{label}_fs_stderr.txt"
    with open(err_path, "wb") as err_fh:
        proc = subprocess.Popen([app_bin, str(port)],
                                stdout=subprocess.PIPE, stderr=err_fh, cwd=app_dir)
        try:
            proc.stdout.readline()
            wait_for_port(port)
            s, f = req(port, b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            code, hdrs, body = read_response(f)
            assert code == 200 and b"Honk Todos" in body, (code, body[:60])
            assert hdrs[b"content-type"] == b"text/html", hdrs
            s.close()
            s, f = req(port, b"GET /some/spa/route HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            code, _, body = read_response(f)
            assert code == 200 and b"Honk Todos" in body, (code, body[:60])
            s.close()
            payload = b'{"title":"e2e milk"}'
            s, f = req(port, b"POST /api/todos HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                             b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(payload) + payload)
            code, _, body = read_response(f)
            assert code == 201, (code, body)
            tid = pyjson.loads(body)["id"]
            s.close()
            s, f = req(port, b"GET /api/todos HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            code, _, body = read_response(f)
            assert code == 200 and pyjson.loads(body) == [
                {"id": tid, "title": "e2e milk", "done": False}], body
            s.close()
            s = socket.create_connection(("127.0.0.1", port), timeout=5.0)
            s.sendall(f"PATCH /api/todos/{tid}/toggle HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
            code, _, _ = read_response(s.makefile("rb"))
            assert code == 200, code
            s.close()
            s, f = req(port, b"GET /api/todos HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            code, _, body = read_response(f)
            assert code == 200 and pyjson.loads(body) == [
                {"id": tid, "title": "e2e milk", "done": True}], body
            s.close()
            s, f = req(port, b"DELETE /api/todos/99999 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            code, _, _ = read_response(f)
            assert code == 404, code
            s.close()
            proc.terminate()
            assert proc.wait(timeout=10) == 0
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait()
    with open(err_path, "rb") as fh:
        err = fh.read()
    for m in (b"AddressSanitizer", b"runtime error:", b"LeakSanitizer", b"SUMMARY:"):
        assert m not in err, f"[{label}-fs] sanitizer hit: {err[-1500:]!r}"
    print("  [PASS] test_fullstack_e2e")


def test_db_fork_and_guard(server_bin, port, label):
    root, dbpath, _ = setup_fixtures(label + "fk")
    try:
        # 1. Forking while a SQLite Db handle is open must abort with a clear hint.
        bad = subprocess.run([server_bin, str(port), root, "badfork", dbpath],
                             capture_output=True, cwd=ROOT, timeout=10)
        assert bad.returncode != 0, "badfork should have aborted"
        assert b"cannot fork 2 workers with an open SQLite handle" in bad.stderr, bad.stderr

        # 2. honk::workers(2) before db_open + SIGTERM drains both WAL workers cleanly.
        err_path = f"/tmp/honkfs_{label}_fk2_stderr.txt"
        with open(err_path, "wb") as err_fh:
            proc = subprocess.Popen([server_bin, str(port), root, "fork2", dbpath],
                                    stdout=subprocess.PIPE, stderr=err_fh, cwd=ROOT)
            try:
                proc.stdout.readline()
                wait_for_port(port)
                for i in range(16):
                    payload = pyjson.dumps({"name": f"fk-{i}", "age": i}).encode()
                    s, f = req(port, b"POST /db HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                                     b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(payload) + payload)
                    code, _, _ = read_response(f)
                    s.close()
                    assert code == 201, code
                s, f = req(port, b"GET /db/all HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                code, _, body = read_response(f)
                s.close()
                assert code == 200 and len(pyjson.loads(body)) == 16, (code, body)
                proc.terminate()
                assert proc.wait(timeout=10) == 0
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait()
        with open(err_path, "rb") as fh:
            err = fh.read()
        for m in (b"AddressSanitizer", b"runtime error:", b"LeakSanitizer", b"SUMMARY:"):
            assert m not in err, f"[{label}-fk2] sanitizer hit: {err[-1500:]!r}"
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("  [PASS] test_db_fork_and_guard (open-db guard + 2-process WAL + SIGTERM LSan exit 0)")


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
    print(f"=== Running Fullstack Suite [{label}] ({server_bin}) ===")
    root, dbpath, big_sha = setup_fixtures(label)
    err_path = f"/tmp/honkfs_{label}_stderr.txt"
    with open(err_path, "wb") as err_fh:
        proc = subprocess.Popen([server_bin, str(port), root, "1", dbpath],
                                stdout=subprocess.PIPE, stderr=err_fh, cwd=ROOT)
        try:
            proc.stdout.readline()
            wait_for_port(port)
            test_static_exact(port, root)
            test_static_head(port, root)
            test_static_big_eagain(port, big_sha)
            test_static_security(port)
            test_static_pipeline(port)
            test_db_crud(port)
            test_db_strings(port)
            test_fd_leak(port, proc.pid)
            s = socket.create_connection(("127.0.0.1", port), timeout=2.0)
            s.sendall(b"POST /__shutdown HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            s.recv(256)
            s.close()
            assert proc.wait(timeout=10) == 0, "exit code"
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait()
            shutil.rmtree(root, ignore_errors=True)
    with open(err_path, "rb") as fh:
        err = fh.read()
    for m in (b"AddressSanitizer", b"runtime error:", b"LeakSanitizer", b"SUMMARY:"):
        assert m not in err, f"[{label}] sanitizer hit: {err[-1500:]!r}"
    test_db_2workers(server_bin, port + 50, label)
    test_db_fork_and_guard(server_bin, port + 55, label)
    test_fullstack_e2e(label)
    print(f"=== ALL 11 FULLSTACK TESTS PASSED [{label}] ===\n")


if __name__ == "__main__":
    binary = sys.argv[1] if len(sys.argv) > 1 else "./test/app_fullstack"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 18440
    label = sys.argv[3] if len(sys.argv) > 3 else "Release"
    run_suite(binary, port, label)
