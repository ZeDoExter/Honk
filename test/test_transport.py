#!/usr/bin/env python3
"""
Transport Correctness Test Suite for Honk (timeouts, caps, soak, edge cases).
Can run against either the release `goose build` binary or an ASan+UBSan instrumented binary.
"""

import os
import socket
import struct
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


def raw_request(port: int, payload: bytes, recv_timeout: float = 3.0) -> bytes:
    with socket.create_connection(("127.0.0.1", port), timeout=3.0) as s:
        s.settimeout(recv_timeout)
        s.sendall(payload)
        chunks = []
        while True:
            try:
                data = s.recv(65536)
                if not data:
                    break
                chunks.append(data)
                if b"\r\n\r\n" in b"".join(chunks):
                    full = b"".join(chunks)
                    hdr, body = full.split(b"\r\n\r\n", 1)
                    cl = 0
                    for line in hdr.split(b"\r\n")[1:]:
                        if line.lower().startswith(b"content-length:"):
                            cl = int(line.split(b":", 1)[1].strip())
                    if len(body) >= cl:
                        break
            except socket.timeout:
                break
        return b"".join(chunks)


def get_stats(port: int) -> dict:
    resp = raw_request(port, b"GET /stats HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    assert b"HTTP/1.1 200 OK" in resp, f"unexpected stats resp: {resp!r}"
    body = resp.split(b"\r\n\r\n", 1)[1].decode("utf-8", errors="replace")
    return parse_stats(body)


def read_n_responses(sock: socket.socket, count: int) -> list:
    buf = bytearray()
    responses = []
    while len(responses) < count:
        while b"\r\n\r\n" not in buf:
            chunk = sock.recv(65536)
            if not chunk:
                raise AssertionError(f"Unexpected EOF after {len(responses)}/{count} responses")
            buf.extend(chunk)
        hdr_end = buf.index(b"\r\n\r\n")
        hdr_bytes = bytes(buf[:hdr_end])
        cl = 0
        for line in hdr_bytes.split(b"\r\n")[1:]:
            if line.lower().startswith(b"content-length:"):
                cl = int(line.split(b":", 1)[1].strip())
        total_need = hdr_end + 4 + cl
        while len(buf) < total_need:
            chunk = sock.recv(65536)
            if not chunk:
                raise AssertionError(
                    f"Unexpected EOF reading body ({len(buf)}/{total_need}) on response {len(responses)}"
                )
            buf.extend(chunk)
        body_bytes = bytes(buf[hdr_end + 4 : total_need])
        del buf[:total_need]
        responses.append((hdr_bytes, body_bytes))
    return responses


def test_01_plaintext_and_date_cache(port: int):
    with socket.create_connection(("127.0.0.1", port), timeout=3.0) as s:
        s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n")
        [(hdr1, body1)] = read_n_responses(s, 1)
        assert hdr1.startswith(b"HTTP/1.1 200 OK\r\n"), hdr1
        assert body1 == b"Hello, World!", body1

        date1 = None
        for line in hdr1.split(b"\r\n")[1:]:
            if line.lower().startswith(b"date:"):
                date1 = line.split(b":", 1)[1].strip()
        assert date1 is not None and len(date1) == 29 and date1.endswith(b"GMT"), date1

        # 404 Not Found on same keep-alive connection
        s.sendall(b"GET /does-not-exist HTTP/1.1\r\nHost: localhost\r\n\r\n")
        [(hdr404, body404)] = read_n_responses(s, 1)
        assert hdr404.startswith(b"HTTP/1.1 404 Not Found\r\n"), hdr404
        assert body404 == b"Not Found", body404

        # Send keep-alive requests every 0.2s (< 0.4s idle_timeout_ms) across 1.2s
        # to verify connection stays alive when active AND 1 Hz Date header cache updates
        date2 = date1
        for _ in range(6):
            time.sleep(0.2)
            s.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
            [(hdr2, body2)] = read_n_responses(s, 1)
            assert body2 == b"Hello, World!"
            for line in hdr2.split(b"\r\n")[1:]:
                if line.lower().startswith(b"date:"):
                    date2 = line.split(b":", 1)[1].strip()
        assert date2 != date1, f"Date header did not update after 1.2s: {date1} == {date2}"
    print("  [PASS] test_01_plaintext_and_date_cache")


def test_02_split_recv_headers_and_body(port: int):
    payload_body = (b"GooseHonkSplitBodyTest0123456789" * 313)[:10000]
    with socket.create_connection(("127.0.0.1", port), timeout=3.0) as s:
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        chunks = [
            b"POST /ec",
            b"ho HTTP/1.1\r\nHost: local",
            b"host\r\nContent-Length: 10000\r\n\r\n" + payload_body[:3000],
            payload_body[3000:6500],
            payload_body[6500:],
        ]
        for ch in chunks:
            s.sendall(ch)
            time.sleep(0.02)

        [(hdr, body)] = read_n_responses(s, 1)
        assert hdr.startswith(b"HTTP/1.1 200 OK\r\n"), hdr
        assert body == payload_body, f"Body mismatch: len={len(body)}"

        # Follow-up keep-alive request on same connection
        s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n")
        [(hdr2, body2)] = read_n_responses(s, 1)
        assert body2 == b"Hello, World!"
    print("  [PASS] test_02_split_recv_headers_and_body")


def test_03_pipelined_requests_with_bodies(port: int):
    b1 = b"first-json-like-body-12345"
    b2 = b"second-body-" + (b"X" * 1200)
    pipeline = (
        b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n"
        + f"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: {len(b1)}\r\n\r\n".encode()
        + b1
        + b"GET /notfound HTTP/1.1\r\nHost: localhost\r\n\r\n"
        + f"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: {len(b2)}\r\n\r\n".encode()
        + b2[:400]
    )
    tail = b2[400:] + b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"

    with socket.create_connection(("127.0.0.1", port), timeout=3.0) as s:
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.sendall(pipeline)
        time.sleep(0.03)
        s.sendall(tail)

        resps = read_n_responses(s, 5)
        assert resps[0][1] == b"Hello, World!"
        assert resps[1][1] == b1
        assert resps[2][0].startswith(b"HTTP/1.1 404 Not Found")
        assert resps[3][1] == b2
        assert resps[4][1] == b"Hello, World!"
        assert b"connection: close" in resps[4][0].lower()
        # Server should close after Connection: close
        assert s.recv(1024) == b""
    print("  [PASS] test_03_pipelined_requests_with_bodies")


def test_04_partial_send_eagain_and_epollout_resume(port: int):
    num_pipelined = 35
    req = b"GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n" * num_pipelined
    expected_body = b"0123456789ABCDEF" * 1024  # 16384 bytes

    st_before = get_stats(port)
    with socket.create_connection(("127.0.0.1", port), timeout=5.0) as s:
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        except OSError:
            pass
        s.sendall(req)
        # Pause reading so server send() hits EAGAIN and queues into pending_tx + EPOLLOUT
        time.sleep(0.15)

        resps = read_n_responses(s, num_pipelined)
        for idx, (hdr, body) in enumerate(resps):
            assert hdr.startswith(b"HTTP/1.1 200 OK"), f"resp {idx}: {hdr}"
            assert body == expected_body, f"resp {idx} body len={len(body)}"

        # Connection must still work after draining pending_tx
        s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n")
        [(hdr_last, body_last)] = read_n_responses(s, 1)
        assert body_last == b"Hello, World!"

    st_after = get_stats(port)
    assert st_after["tx_queued"] > st_before["tx_queued"], (
        f"Expected EAGAIN pending_tx queueing, got {st_before} -> {st_after}"
    )
    print(f"  [PASS] test_04_partial_send_eagain_and_epollout_resume (tx_queued={st_after['tx_queued'] - st_before['tx_queued']})")


def test_05_max_header_431_and_max_body_413(port: int):
    # 1. Single-recv header > 8192 bytes -> 431
    big_hdr = b"GET / HTTP/1.1\r\nHost: localhost\r\nX-Oversize: " + (b"H" * 8300) + b"\r\n\r\n"
    resp431 = raw_request(port, big_hdr)
    assert resp431.startswith(b"HTTP/1.1 431 Request Header Fields Too Large"), resp431

    # 2. Split-recv header > 8192 bytes without \r\n\r\n -> 431
    with socket.create_connection(("127.0.0.1", port), timeout=3.0) as s:
        s.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nX-Split-Big: " + (b"S" * 4500))
        time.sleep(0.02)
        s.sendall(b"S" * 4500)
        [(hdr431_s, _)] = read_n_responses(s, 1)
        assert hdr431_s.startswith(b"HTTP/1.1 431 Request Header Fields Too Large"), hdr431_s

    # 3. Content-Length > 1048576 (1 MiB) -> 413 Payload Too Large
    req413 = b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048577\r\n\r\nhello"
    resp413 = raw_request(port, req413)
    assert resp413.startswith(b"HTTP/1.1 413 Payload Too Large"), resp413

    # 4. Exact 1 MiB (1048576 bytes) body -> 200 OK
    body_1mb = b"M" * 1048576
    with socket.create_connection(("127.0.0.1", port), timeout=5.0) as s:
        s.sendall(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048576\r\n\r\n" + body_1mb)
        [(hdr200, echoed)] = read_n_responses(s, 1)
        assert hdr200.startswith(b"HTTP/1.1 200 OK"), hdr200
        assert len(echoed) == 1048576 and echoed == body_1mb
    print("  [PASS] test_05_max_header_431_and_max_body_413")


def test_06_chunked_501_and_malformed_400(port: int):
    # 1. Valid single-recv Transfer-Encoding: chunked (+ chunk-ext + trailer) -> 200 OK
    req_chunked = (
        b"POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n"
        b"5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nX-Trailer: ok\r\n\r\n"
    )
    resp_ch = raw_request(port, req_chunked)
    assert resp_ch.startswith(b"HTTP/1.1 200 OK") and resp_ch.endswith(b"\r\n\r\nhello world"), resp_ch

    # 2. Split-recv Transfer-Encoding: chunked (mid-hex, mid-data, mid-0) + pipelined keep-alive GET
    with socket.create_connection(("127.0.0.1", port), timeout=3.0) as s:
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        pieces = [
            b"POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: CHUNKED\r\n\r\n4",
            b"\r\nab",
            b"cd\r\n3\r\nXYZ\r\n0\r",
            b"\n\r\nGET /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n",
        ]
        for p in pieces:
            s.sendall(p)
            time.sleep(0.02)
        resps = read_n_responses(s, 2)
        assert resps[0][0].startswith(b"HTTP/1.1 200 OK") and resps[0][1] == b"abcdXYZ", resps[0]
        assert resps[1][0].startswith(b"HTTP/1.1 200 OK") and resps[1][1] == b"Hello, World!", resps[1]

    # 3. Oversize chunked (> 1 MiB) -> 413 Payload Too Large
    resp413_ch = raw_request(
        port,
        b"POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n100001\r\nhello",
    )
    assert resp413_ch.startswith(b"HTTP/1.1 413 Payload Too Large"), resp413_ch

    # 4. CL + TE request smuggling attempt -> 400 Bad Request
    resp400_smug = raw_request(
        port,
        b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
    )
    assert resp400_smug.startswith(b"HTTP/1.1 400 Bad Request"), resp400_smug

    # 5. Malformed chunk size -> 400 Bad Request
    resp400_ch = raw_request(
        port,
        b"POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\nZZ\r\n",
    )
    assert resp400_ch.startswith(b"HTTP/1.1 400 Bad Request"), resp400_ch

    # 6. Unsupported Transfer-Encoding (gzip) -> 501 Not Implemented
    req501 = b"POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip\r\n\r\n"
    resp501 = raw_request(port, req501)
    assert resp501.startswith(b"HTTP/1.1 501 Not Implemented"), resp501

    # 7. Malformed request line & invalid Content-Length -> 400 Bad Request
    resp400_a = raw_request(port, b"NOT AN HTTP REQUEST\r\n\r\n")
    assert resp400_a.startswith(b"HTTP/1.1 400 Bad Request"), resp400_a

    resp400_b = raw_request(port, b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: -12abc\r\n\r\n")
    assert resp400_b.startswith(b"HTTP/1.1 400 Bad Request"), resp400_b
    print("  [PASS] test_06_chunked_501_and_malformed_400")


def test_07_idle_timeout_peer_close_and_peer_reset(port: int):
    # 1. Clean peer close without sending
    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as s:
        pass

    # 2. Peer TCP RST (SO_LINGER with l_onoff=1, l_linger=0)
    s_rst = socket.create_connection(("127.0.0.1", port), timeout=2.0)
    s_rst.sendall(b"GET /partial-before-rst HTTP/1.1\r\n")
    time.sleep(0.02)
    s_rst.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    s_rst.close()

    # 3. Idle connection timeout (server runs with idle_timeout_ms=400, header_timeout_ms=500)
    st_before = get_stats(port)
    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as s_idle:
        time.sleep(0.65)
        data = s_idle.recv(1024)
        assert data == b"", f"Expected idle connection to be closed by server, got {data!r}"
    st_after = get_stats(port)
    assert st_after["timed_out"] > st_before["timed_out"], (st_before, st_after)
    print("  [PASS] test_07_idle_timeout_peer_close_and_peer_reset")


def test_08_slowloris_and_never_reading_client(port: int):
    # 1. Slowloris client: sends bytes every 80ms (< 400ms idle_timeout_ms)
    #    but never finishes headers within 500ms header_timeout_ms!
    st_before = get_stats(port)
    with socket.create_connection(("127.0.0.1", port), timeout=2.0) as s_slow:
        s_slow.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s_slow.sendall(b"GET /slow HTTP/1.1\r\nHost: localhost\r\nX-Trickle: ")
        closed_by_server = False
        for _ in range(15):
            time.sleep(0.08)
            try:
                s_slow.sendall(b"a")
                s_slow.setblocking(False)
                try:
                    d = s_slow.recv(1024)
                    if d == b"":
                        closed_by_server = True
                        break
                except BlockingIOError:
                    pass
                finally:
                    s_slow.setblocking(True)
            except (BrokenPipeError, ConnectionResetError):
                closed_by_server = True
                break
        assert closed_by_server, "Slowloris connection was not terminated by header_timeout_ms"
    st_after = get_stats(port)
    assert st_after["timed_out"] > st_before["timed_out"], (st_before, st_after)

    # 2. Never-reading client: sends 120 pipelined GET /large (120 * 16 KiB = 1.92 MiB > 1 MiB pending_tx cap)
    #    and never reads from socket -> server must close connection cleanly when pending_tx exceeds 1 MiB.
    with socket.create_connection(("127.0.0.1", port), timeout=3.0) as s_nr:
        try:
            s_nr.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        except OSError:
            pass
        burst = b"GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n" * 120
        try:
            s_nr.sendall(burst)
        except (BrokenPipeError, ConnectionResetError):
            pass
        time.sleep(0.15)
    # Verify server is healthy and active connections returned to 1 (the stats connection)
    st_clean = get_stats(port)
    assert st_clean["active"] == 1, f"Expected active=1 after cleanup, got {st_clean}"
    print("  [PASS] test_08_slowloris_and_never_reading_client")


def test_09_5000_plus_connections_cap(port: int):
    # Open 5,100 connections against a server with idle_timeout_ms=30000 and cap=4096.
    target_conns = 5100
    socks = []
    st0 = get_stats(port)
    rej_before = st0["rejected"]

    try:
        for _ in range(target_conns):
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(2.0)
            s.connect(("127.0.0.1", port))
            socks.append(s)

        # Wait briefly for the server accept4 loop to accept 4096 and reject the rest
        time.sleep(0.25)

        # Verify that one of the first accepted sockets still serves requests at full cap!
        socks[0].sendall(b"GET /stats HTTP/1.1\r\nHost: localhost\r\n\r\n")
        [(hdr, body)] = read_n_responses(socks[0], 1)
        assert hdr.startswith(b"HTTP/1.1 200 OK"), hdr
        st_cap = parse_stats(body.decode())
        assert st_cap["active"] == 4096, f"Expected active==4096 at cap, got {st_cap}"
        rejected_delta = st_cap["rejected"] - rej_before
        assert rejected_delta == (target_conns - 4096), (
            f"Expected {target_conns - 4096} rejected connections, got {rejected_delta} ({st_cap})"
        )

        # Verify an excess connection (> 4096) was cleanly closed by server
        excess_sock = socks[-1]
        try:
            d = excess_sock.recv(1024)
            assert d == b"", f"Expected EOF on rejected connection, got {d!r}"
        except ConnectionResetError:
            pass
    finally:
        for s in socks:
            try:
                s.close()
            except Exception:
                pass

    time.sleep(0.15)
    st_end = get_stats(port)
    assert st_end["active"] == 1, f"Expected active==1 after closing 5100 conns, got {st_end}"
    print(f"  [PASS] test_09_5000_plus_connections_cap (opened={target_conns}, capped=4096, rejected={target_conns - 4096})")


def wait_for_port(port: int, timeout: float = 5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5) as s:
                s.sendall(b"GET /plaintext HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                resp = s.recv(1024)
                if b"200 OK" in resp:
                    return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError(f"Server on port {port} did not become ready within {timeout}s")


def run_suite(server_bin: str, base_port: int, label: str):
    print(f"=== Running Transport Correctness Suite [{label}] ({server_bin}) ===")
    # 1. Normal-timeout server instance (idle_timeout_ms=30000, header_timeout_ms=10000) for tests 1..6 and 9
    port_norm = base_port
    proc_norm = subprocess.Popen(
        [server_bin, str(port_norm), "30000", "10000", "1"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        line = proc_norm.stdout.readline()
        assert "listening on port" in line, f"Server failed to start: {line} / {proc_norm.stderr.read()}"
        wait_for_port(port_norm)
        test_01_plaintext_and_date_cache(port_norm)
        test_02_split_recv_headers_and_body(port_norm)
        test_03_pipelined_requests_with_bodies(port_norm)
        test_04_partial_send_eagain_and_epollout_resume(port_norm)
        test_05_max_header_431_and_max_body_413(port_norm)
        test_06_chunked_501_and_malformed_400(port_norm)
        test_09_5000_plus_connections_cap(port_norm)
    finally:
        try:
            raw_request(port_norm, b"POST /__shutdown HTTP/1.1\r\nHost: localhost\r\n\r\n", recv_timeout=1.0)
        except Exception:
            proc_norm.terminate()
        try:
            _, stderr_norm = proc_norm.communicate(timeout=3.0)
        except subprocess.TimeoutExpired:
            proc_norm.kill()
            _, stderr_norm = proc_norm.communicate()
        if stderr_norm.strip() or proc_norm.returncode != 0:
            print(f"STDERR from {label} normal server (rc={proc_norm.returncode}):\n{stderr_norm}")
            raise AssertionError(f"Sanitizer or runtime error (rc={proc_norm.returncode}): {stderr_norm}")

    # 2. Fast-timeout server instance (idle_timeout_ms=400, header_timeout_ms=500) for timeout & slowloris tests 7..8
    port_fast = base_port + 1
    proc_fast = subprocess.Popen(
        [server_bin, str(port_fast), "400", "500", "1"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        line = proc_fast.stdout.readline()
        assert "listening on port" in line, f"Server failed to start: {line}"
        wait_for_port(port_fast)
        test_07_idle_timeout_peer_close_and_peer_reset(port_fast)
        test_08_slowloris_and_never_reading_client(port_fast)
    finally:
        try:
            raw_request(port_fast, b"POST /__shutdown HTTP/1.1\r\nHost: localhost\r\n\r\n", recv_timeout=1.0)
        except Exception:
            proc_fast.terminate()
        try:
            _, stderr_fast = proc_fast.communicate(timeout=3.0)
        except subprocess.TimeoutExpired:
            proc_fast.kill()
            _, stderr_fast = proc_fast.communicate()
        if stderr_fast.strip() or proc_fast.returncode != 0:
            print(f"STDERR from {label} fast server (rc={proc_fast.returncode}):\n{stderr_fast}")
            raise AssertionError(f"Sanitizer or runtime error (rc={proc_fast.returncode}): {stderr_fast}")

    print(f"=== ALL 9 CORRECTNESS TESTS PASSED [{label}] ===\n")


if __name__ == "__main__":
    binary = sys.argv[1] if len(sys.argv) > 1 else "./src/server_minimal"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 18100
    label = sys.argv[3] if len(sys.argv) > 3 else "Release"
    run_suite(binary, port, label)
