# Phase 1 — Step 1a Spike Report

> **Environment Note (WSL2)**: All performance measurements below were collected on WSL2 (Ubuntu 24.04.4 LTS, kernel `6.6.87.2-microsoft-standard-WSL2`, Intel Core i5-10300H @ 2.50 GHz, 4 physical cores / 8 threads) and are **indicative only**; final claims require native Linux.

---

## 1. Physical Core Mapping (`lscpu -e`) & Pinning Strategy

```text
CPU NODE SOCKET CORE L1d:L1i:L2:L3 ONLINE
  0    0      0    0 0:0:0:0          yes
  1    0      0    0 0:0:0:0          yes
  2    0      0    1 1:1:1:0          yes
  3    0      0    1 1:1:1:0          yes
  4    0      0    2 2:2:2:0          yes
  5    0      0    2 2:2:2:0          yes
  6    0      0    3 3:3:3:0          yes
  7    0      0    3 3:3:3:0          yes
```

- **Server Pinning**: `taskset -c 0` (Physical Core 0; sibling hyperthread CPU 1 left idle).
- **Load Generator Pinning**: `taskset -c 4,6 wrk -t2 -c64 -d10s --latency` (Physical Cores 2 and 3, one thread per physical core; sibling hyperthreads 5 and 7 left idle).
- **OS / Interrupt Headroom**: Physical Core 1 (CPUs 2, 3) left unassigned.

---

## 2. Amendment D: Goose Compiler Thread Test Suite Results

Ran all thread-related tests in `goose_repo/test/` against `goose_repo/build-linux/goose` (`v2026.4-78-g2239b92e`, GCC 13.3.0):

| Section | Checks Passed | Failures |
|---|---:|---:|
| `test/threads/*.goose` — parse, roundtrip, and typecheck | 66 | 0 |
| `test/threads/*.goose` — generated C (`-O0` and `-O2` compile + run) | 33 | 0 |
| `test/threads/*.goose` — `GS_DEBUG=1` runtime checks | 2 | 0 |
| Native lifecycle (`runtime_threads_lifecycle.c`), `host_exit`, `exit_race` | 4 | 0 |
| Thread-related compiler rejection tests (`test/errors*/*thread*.goose`) | 31 | 0 |
| **Total** | **136** | **0** |

 Notably, `test/threads/slot_pool_worker.goose`, `test/threads/slice_pool_worker.goose`, and `test/threads/root_worker_local.goose` all passed at `-O0` and `-O2`.

---

## 3. Amendment A: `gs_rref` Verification & Buffer Design Prototypes

### 3.1 `extern fn` + `u8[>..]&` (`gs_rref`) Verification
- Wrote and compiled [verify_rref.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/verify_rref.goose), [verify_rref.build](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/verify_rref.build), and [verify_rref_shim.c](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/verify_rref_shim.c).
- Verified both runtime execution inside a `thread_fn` worker and the generated C:
  - At scope entry: `rx_buf_g.base = GS(gs_sp + 0)->top; rx_buf_g.len = 0;`
  - Across `extern fn`: passes `gs_rref { hdr: &rx_buf_g, stk: GS(gs_sp + 0) }`; C writes directly into `out.stk->top` and increments `out.stk->top += n; out.hdr->len += n;`.
  - At scope exit: `GS(gs_sp + 0)->top = rx_buf_g.base;` (single pointer store).

### 3.2 Functional Verification of All Servers
Before benchmarking, verified `bare_c_control`, `spike_d1`, `spike_d2`, and `spike_d3` against:
1. Standard `GET /plaintext` keep-alive requests (`200 OK`, dynamic `Content-Length: 13`, 1 Hz thread-local `Date` header, `"Hello, World!"` body).
2. Request split across 3 separate `send()` calls with 50 ms pauses across `epoll_wait` iterations (`"GET /plain"`, `"text HTTP/1.1\r\nHost: loc"`, `"alhost\r\n\r\n"`).
3. 3x HTTP pipelined requests sent in a single packet returning 3 back-to-back responses.

---

## 4. Step 1a Benchmark Results (`wrk -t2 -c64 -d10s --latency`, 5 Runs After 3s Warmup)

*Indicative only (WSL2 Linux 6.6.87.2, server on CPU 0 [Core 0], `wrk` on CPUs 4,6 [Cores 2,3]).*

### Raw Runs (`Requests/sec`)

| Server / Buffer Design | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 | **Median req/s** | Min – Max Spread | **vs. Bare-C Control** | Peak RSS (`VmHWM`) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **Bare-C Control** ([server_c.c](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/bench/c_control/server_c.c)) | 135,523.56 | 123,407.51 | 95,739.03 | 129,784.37 | 126,253.88 | **126,253.88** | 95,739 – 135,524 | **100.00%** (baseline) | 18,048 kB |
| **Goose Candidate (i)**: `slot_pool<ConnBuf>` `u8[..16384]` ([spike_d1.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/spike_d1.goose)) | 131,711.25 | 99,676.24 | 82,242.78 | 98,627.99 | 129,805.35 | **99,676.24** | 82,243 – 131,711 | **78.95%** | 34,432 kB |
| **Goose Candidate (ii)**: C per-conn buffer copied to Goose scope ([spike_d2.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/spike_d2.goose)) | 118,791.23 | 143,046.31 | 145,425.43 | 91,184.53 | 115,107.11 | **118,791.23** | 91,185 – 145,425 | **94.09%** | 18,048 kB |
| **Goose Candidate (iii)**: Direct-to-`gs_rref` `recv()` + C partial-tail stash ([spike_d3.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/spike_d3.goose)) | 114,543.58 | 130,257.41 | 126,254.78 | 113,813.21 | 127,352.82 | **126,254.78** | 113,813 – 130,257 | **100.00%** | 18,048 kB |

---

## 5. Diagnostics (`--bce-lines`, Generated C, and `strace -c`)

Even though all three Goose candidates exceeded the 70% tripwire (78.95%, 94.09%, and 100.00%), we ran the full diagnostic checklist:

1. **Bounds Check Elimination (`goose check --bce-lines src/spike/spike_d3.goose`)**:
   - `ready_fds[i]` in the event loop is **elided** (`1 elided, 0 kept`) thanks to `assert(nfds <= 256);`.
   - The only remaining runtime checks in the hot loop are the 3 sub-slice range checks on the untrusted C offset spans (`rx_buf[cursor..]`, `rem_slice[req.method_off .. req.method_end]`, `rem_slice[req.path_off .. req.path_end]`).
2. **Generated C Inspection**:
   - `handle_request` and `write_response` are completely inlined into `worker_d3_g`.
   - The response data-stack top pointer (`t108`) is held in a register throughout response assembly; every `out.append(...)` compiles directly to `gs_memcpy(t108, ...); t108 += len; tx_buf_g.len += len;`.
   - Scope exit resets both `rx_buf` and `tx_buf` data stacks in two stores (`GS(gs_sp + 0)->top = rx_buf_g.base; GS(gs_sp + 1)->top = tx_buf_g.base;`).
3. **Syscall Profile (`strace -c -f` over a 2s `wrk -t2 -c64` burst)**:
   - **Bare-C Control**: `36,576 sendto`, `36,576 recvfrom`, `658 epoll_wait`, `67 accept4`, `131 epoll_ctl`, `68 close`.
   - **Goose Candidate (iii) (`spike_d3`)**: `43,191 sendto`, `43,191 recvfrom`, `686 epoll_wait`, `67 accept4`, `131 epoll_ctl`, `69 close`, `1 futex` (main thread waiting in `thread_wait`).
   - **Zero extra syscalls**: Goose makes the exact same `recvfrom`, `sendto`, and `epoll_wait` calls per request as the bare-C control.

---

## 6. Chosen Buffer Design for Step 1b

We choose **Candidate (iii): Direct-to-Goose-Data-Stack `recv()` (`gs_rref`) on the fast path + C thread-local per-connection buffers for split-`recv()` partial tails and partial-`send()` `EAGAIN` queues**:
- Achieves **100.00%** of the bare-C control median throughput (`126,254.78` vs `126,253.88` req/s) with the tightest run-to-run spread.
- In Step 1b, we will also make each connection's partial-rx and pending-tx buffers in `tls_conns` allocate lazily on demand (rather than pre-allocating a fixed 16 KB `rx_buf[16384]` inside every `shim_conn_t` slot), which will drop the worker's idle connection table footprint from 16 MB down to ~64 KB while supporting configurable `MAX_HEADER_SIZE` (431) and `MAX_BODY_SIZE` (413).
