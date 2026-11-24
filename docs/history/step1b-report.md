# Phase 1, Step 1b Report — Full HTTP/1.1 Network Layer, Stack Discipline, Limits & Fixed Measurement Protocol

## 1. Executive Summary
- **Goal**: Complete the Phase 1 HTTP/1.1 network layer ([src/shim/honk_shim.c](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/shim/honk_shim.c), [src/shim/honk_rref.h](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/shim/honk_rref.h), [src/honk_net/honk_net.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/honk_net/honk_net.goose), [src/server_minimal.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/server_minimal.goose)) implementing Amendment C and Requirements E, F, G, and H.
- **Buffer Design Changes Required**: **None**. Design (iii) (direct-to-Goose-data-stack `recv()` on the fast path + lazily allocated C thread-local `partial_rx` and `pending_tx` buffers across `epoll` events) handled every requirement cleanly without changing the buffer architecture.
- **Anything That Could Not Be Done**: **None** — every item in Amendment C and Requirements E, F, G, and H was implemented, compiled, and verified.

---

## 2. Requirement E: Stack Discipline Isolation, 100k+ Error-Path Test, and ASan/UBSan

### E.1. Single-Header `gs_rref` Isolation & Compile-Time Layout Checks
- All manipulation of `gs_rref`, `gs_rhdr` (`base`, `len`), and `gs_stack` (`top`) is isolated in a single 92-line header: [src/shim/honk_rref.h](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/shim/honk_rref.h).
- No other C file in `src/shim/` accesses `r.hdr`, `r.stk`, `hdr->base`, `hdr->len`, or `stk->top` directly.
- Compile-time `_Static_assert` checks in [src/shim/honk_rref.h](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/shim/honk_rref.h#L19-L29) verify every size and field offset of `gs_stack` (`8` bytes, `top` at `0`), `gs_rhdr` (`16` bytes, `base` at `0`, `len` at `8`), and `gs_rref` (`16` bytes, `hdr` at `0`, `stk` at `8`) against `goose.h`.
- The pinned Goose compiler commit (`2239b92eb2ae0e8f390f98640b09ff57a17698fc` / `v2026.4-78-g2239b92e`, runtime hash `68cc5acec0ef`) is recorded in [docs/DECISIONS.md](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/docs/DECISIONS.md#L50-L53).

### E.2. 100,000-Iteration Stack Discipline Test Across All 9 Paths (900,000 Total Turns)
- Test program: [test/test_stack_discipline.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/test/test_stack_discipline.goose) + [test/test_stack_helper.c](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/test/test_stack_helper.c).
- Exercises the unmodified `process_ready_fd` -> `honk_conn_read` -> `honk_parse_req` -> `honk_send` -> `honk_conn_finish` / timeout sweep paths **100,000 times per path** (`900,000` iterations total) and asserts `honk_debug_stack_top(rx_buf) == baseline` on every single turn and afterwards:

| Path | Description | Iterations | Baseline `stk->top` | Final `stk->top` | Result |
|---|---|---:|---:|---:|---|
| 1 | `success` (`200 OK` full request/response cycle) | `100,000` | `123352573280256` | `123352573280256` | **PASS** |
| 2 | `EAGAIN` (`50k` empty + `50k` with `partial_rx` prepended onto `rx_buf` then rolled back) | `100,000` | `123352573280256` | `123352573280256` | **PASS** |
| 3 | `recv() == 0` (EOF / peer close with `partial_rx` prepended then rolled back) | `100,000` | `123352573280256` | `123352573280256` | **PASS** |
| 4 | `recv() == -1` / peer reset (`ENOTCONN`/`ECONNRESET` with `partial_rx` prepended then rolled back) | `100,000` | `123352573280256` | `123352573280256` | **PASS** |
| 5 | `431 Request Header Fields Too Large` (`> 8192` byte header reject & close) | `100,000` | `123352573280256` | `123352573280256` | **PASS** |
| 6 | `413 Payload Too Large` (`Content-Length > 1048576` reject & close) | `100,000` | `123352573280256` | `123352573280256` | **PASS** |
| 7 | `501 Not Implemented` (`Transfer-Encoding: chunked` reject & close) | `100,000` | `123352573280256` | `123352573280256` | **PASS** |
| 8 | `400 Bad Request` (malformed HTTP request reject & close) | `100,000` | `123352573280256` | `123352573280256` | **PASS** |
| 9 | `timeout` (partial header read into `rx_buf`, stashed in `partial_rx`, swept by timeout) | `100,000` | `123352573280256` | `123352573280256` | **PASS** |

### E.3. AddressSanitizer + UndefinedBehaviorSanitizer (`-fsanitize=address,undefined -fno-sanitize-recover=all`)
- Built both `test_stack_discipline_asan` and `server_minimal_asan` by emitting standalone C (`goose -o ... --standalone`) and compiling the Goose program, Goose runtime, `honk_shim.c`, and `picohttpparser.c` together with `gcc -O2 -g -fsanitize=address,undefined -fno-sanitize-recover=all`.
- The server supports clean worker shutdown (`honk_worker_shutdown()`) so `main()` exits with status `0` and **LeakSanitizer (LSan)** runs full end-of-process heap leak verification.
- **Findings**:
  - **0 ASan/UBSan/LSan errors** across all 900,000 iterations of `test_stack_discipline_asan` and across all 9 test suites in `test/test_transport.py`.
  - During development of Path 8 (`400 Bad Request`), we uncovered a subtle `picohttpparser` edge case: when a malformed request line has `< 9` bytes remaining after the path (e.g., `"BAD REQUEST LINE\r\n\r\n"` where `"LINE\r\n\r\n"` is 8 bytes), `picohttpparser`'s `parse_http_version` checks `if (buf_end - buf < 9) return -2;` (incomplete) before checking if `\r\n\r\n` has already ended the header block. We fixed this in [src/shim/honk_shim.c](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/shim/honk_shim.c#L524-L526) (and identically in [bench/c_control/server_c.c](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/bench/c_control/server_c.c#L479-L483)) by checking `if (pret == -2 && scan_len >= 4 && memmem(buf.data, scan_len, "\r\n\r\n", 4) != NULL) return -400;`.

---

## 3. Amendment C & Requirement F: Correctness Suite, Resource Caps, and 10-Minute Soak

### 3.1. Resource Caps & Lazy Buffer Architecture ([src/shim/honk_shim.c](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/shim/honk_shim.c))
- **Active connection cap**: `HONK_MAX_CONNS = 4096` per worker (`HONK_MAX_FD = 16384`). Excess connections accepted when `tls_active_conns >= 4096` are immediately closed (`close(cfd)`) and counted in `tls_rejected_conns`.
- **Lazy per-connection buffers**: `tls_conns` is allocated with `calloc(HONK_MAX_FD, sizeof(honk_conn_t))` (80 bytes/slot, zeroed virtual pages not faulted until an `fd` is used). Each connection's `partial_rx` and `pending_tx` pointers are `NULL` when idle, lazily allocated via `realloc` only when a split request tail or `EAGAIN` response tail exists, and `free()`d immediately when drained or when the connection closes.
- **Explicit buffer limits**:
  - `HONK_MAX_HEADER_SIZE = 8192` bytes (`> 8192` -> `431 Request Header Fields Too Large`, close).
  - `HONK_MAX_BODY_SIZE = 1048576` bytes (1 MiB; `Content-Length > 1048576` -> `413 Payload Too Large`, close).
  - `HONK_MAX_PENDING_TX = 1048576` bytes (1 MiB; if an unread client causes `pending_tx` to exceed 1 MiB -> close connection and free `pending_tx`).
  - `Transfer-Encoding: chunked` -> `501 Not Implemented`, close (documented in [docs/DECISIONS.md](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/docs/DECISIONS.md#L69)).

### 3.2. Full Correctness Test Suite ([test/test_transport.py](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/test/test_transport.py))
All 9 tests passed on both **Release (`./src/server_minimal`)** and **ASan+UBSan (`./src/server_minimal_asan`)**:

| Test | Requirement Verified | Release | ASan+UBSan |
|---|---|---|---|
| `test_01_plaintext_and_date_cache` | `GET /`, `GET /plaintext`, `404`, dynamic `Content-Length`, 1 Hz cached `Date` update across keep-alive | **PASS** | **PASS** |
| `test_02_split_recv_headers_and_body` | `POST /echo` with 10 KB body split across 5 `send()` chunks (mid-path, mid-header, 3 body chunks) + keep-alive follow-up | **PASS** | **PASS** |
| `test_03_pipelined_requests_with_bodies` | 5 pipelined requests (`GET`, `POST /echo`, `404`, split `POST /echo`, `Connection: close`) in order | **PASS** | **PASS** |
| `test_04_partial_send_eagain_and_epollout_resume` | 35 pipelined 16 KiB `GET /large` responses with small socket buffers; verifies `tx_queued >= 1` (`EAGAIN`), `EPOLLOUT` resumption, and intact payload | **PASS** | **PASS** |
| `test_05_max_header_431_and_max_body_413` | Single-recv & split-recv `> 8192` B header -> `431`; `Content-Length: 1048577` -> `413`; exact `1048576` (1 MiB) body -> `200 OK` | **PASS** | **PASS** |
| `test_06_chunked_501_and_malformed_400` | `Transfer-Encoding: chunked` -> `501`; malformed request line & negative/alpha `Content-Length` -> `400` | **PASS** | **PASS** |
| `test_07_idle_timeout_peer_close_and_peer_reset` | Clean peer close (`recv()==0`), peer TCP `RST` (`SO_LINGER(1,0)`), and idle timeout sweep | **PASS** | **PASS** |
| `test_08_slowloris_and_never_reading_client` | Slowloris trickling 1 byte every 80 ms (`< idle_timeout_ms`) killed by `header_timeout_ms`; never-reading client exceeding 1 MiB `pending_tx` cap closed cleanly | **PASS** | **PASS** |
| `test_09_5000_plus_connections_cap` | Opens `5,100` concurrent connections: `active` capped at `4096`, `1,004` excess cleanly rejected, active connections continue serving `200 OK`, clean recovery to `active=1` | **PASS** | **PASS** |

### 3.3. 10-Minute RSS Soak Test ([test/test_10min_soak.py](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/test/test_10min_soak.py), [bench/soak_10min_rss.json](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/bench/soak_10min_rss.json))
- Ran a continuous `connect -> request -> close` loop for **600 seconds (10 minutes)** against `./src/server_minimal`, completing **138,681 connections** (`~231 conns/sec`).
- Every 4th connection (`34,670` connections) sent a split-`recv()` 2,048-byte `POST /echo` across two separate `send()` calls with `TCP_NODELAY` and a 1 ms gap, continuously exercising lazy `c->partial_rx` `realloc()` and `free()` on drain/close.
- Sampled `VmRSS` and `VmHWM` from `/proc/<pid>/status` every 30 seconds:

| Elapsed (`s`) | Completed Connections | `VmRSS` (`kB`) | `VmHWM` (`kB`) |
|---:|---:|---:|---:|
| `0s` | `0` | `1,408` | `1,408` |
| `30s` *(warm-up)* | `6,569` | `1,408` | `1,408` |
| `60s` | `13,663` | `1,408` | `1,408` |
| `120s` | `27,843` | `1,408` | `1,408` |
| `180s` | `41,970` | `1,408` | `1,408` |
| `240s` | `56,034` | `1,408` | `1,408` |
| `300s` | `69,627` | `1,408` | `1,408` |
| `360s` | `83,396` | `1,408` | `1,408` |
| `420s` | `97,049` | `1,408` | `1,408` |
| `480s` | `110,916` | `1,408` | `1,408` |
| `540s` | `124,767` | `1,408` | `1,408` |
| `600s` *(final)* | `138,681` | `1,408` | `1,408` |

- **Result**: Warm-up (30s) `VmRSS = 1,408 kB` -> Final (600s) `VmRSS = 1,408 kB` (**`+0 kB` drift** across 138,681 connections).

---

## 4. Requirement G: Fixed Measurement Protocol (Indicative Only — WSL2)

### G.1. `curl -i` Byte-Equivalence ([bench/curl_c_control.txt](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/bench/curl_c_control.txt) vs [bench/curl_goose_honk.txt](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/bench/curl_goose_honk.txt))
Both responses are **115 bytes** and **100% byte-identical**:
```http
HTTP/1.1 200 OK
Content-Type: text/plain
Date: Tue, 24 Nov 2026 12:12:13 GMT
Content-Length: 13

Hello, World!
```
Both servers perform the exact same per-turn work: `epoll_wait`, `clock_gettime(CLOCK_MONOTONIC)` + 1 Hz `clock_gettime(CLOCK_REALTIME)` `Date` cache, non-blocking `recv()`, `picohttpparser` request parsing with strict `Content-Length` / `Transfer-Encoding` / size checks, dynamic integer formatting of status code and `Content-Length`, and `send(..., MSG_NOSIGNAL)` with `EAGAIN` queueing.

### G.2. Proper Memory (`VmRSS` and `VmHWM`) at Idle, 64 Connections, and 1024 Connections ([bench/rss_measurements.json](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/bench/rss_measurements.json))
Replacing Step 1a's pre-faulted inline 16 KB buffer array with lazy per-connection buffer allocation reduced Honk's memory footprint by **12.8x** (`18,048 kB` -> `1,408 kB`):

| Server | Idle (0 conns) `VmRSS` / `VmHWM` | 64 Active Conns `VmRSS` / `VmHWM` | 1024 Active Conns `VmRSS` / `VmHWM` |
|---|---:|---:|---:|
| **Bare-C Control** (`bench/c_control/server_c`) | `1,408 kB` / `1,408 kB` | `1,536 kB` / `1,536 kB` | `1,536 kB` / `1,536 kB` |
| **Goose Honk (Phase 1)** (`src/server_minimal`) | `1,408 kB` / `1,408 kB` | `1,408 kB` / `1,408 kB` | `1,408 kB` / `1,408 kB` |

### G.3. 7-Round Interleaved Benchmark (`C, Goose, C, Goose, ...`) with `pidstat` and CPU Time per Request ([bench/bench_transport_results.json](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/bench/bench_transport_results.json))
- **Setup**: Single worker pinned to CPU `0` (Physical Core 0); `wrk -t2 -c64 -d10s --latency` pinned to CPUs `4,6` (Physical Cores 2 & 3). All numbers are **indicative only (WSL2)**.
- **Round-by-Round Data (Round 1 discarded as warmup)**:

| Round | Server | `req/s` | Total CPU/req (`µs`) | User CPU/req (`µs`) | Sys CPU/req (`µs`) | Server CPU% (`pidstat`) | `wrk` CPU% (`pidstat`) | `p99` Latency | Saturation Status |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---|
| 1 *(warmup)* | Bare-C Control | `95,874.55` | `10.639` | `0.729` | `9.910` | `101.2%` | `135.9%` | `5.38ms` | `SERVER-CORE-BUSY` |
| 1 *(warmup)* | Goose Honk | `129,542.36` | `7.947` | `0.611` | `7.336` | `103.0%` | `137.0%` | `2.71ms` | `SERVER-CORE-BUSY` |
| **2** | **Bare-C Control** | `110,991.12` | `8.197` | `0.577` | `7.621` | `99.0%` | `132.6%` | `751.47ms` | `SERVER-CORE-BUSY` |
| **2** | **Goose Honk** | `104,482.15` | `9.816` | `0.698` | `9.118` | `101.6%` | `129.5%` | `7.45ms` | `SERVER-CORE-BUSY` |
| **3** | **Bare-C Control** | `115,161.67` | `8.915` | `0.582` | `8.333` | `102.2%` | `137.1%` | `2.36ms` | `SERVER-CORE-BUSY` |
| **3** | **Goose Honk** | `86,138.03` | `10.610` | `0.732` | `9.877` | `99.2%` | `124.8%` | `757.64ms` | `SERVER-CORE-BUSY` |
| **4** | **Bare-C Control** | `99,747.97` | `10.177` | `0.721` | `9.457` | `100.5%` | `134.1%` | `4.81ms` | `SERVER-CORE-BUSY` |
| **4** | **Goose Honk** | `111,387.13` | `9.230` | `0.646` | `8.584` | `102.9%` | `131.8%` | `2.21ms` | `SERVER-CORE-BUSY` |
| **5** | **Bare-C Control** | `98,896.33` | `10.095` | `0.556` | `9.539` | `99.8%` | `128.1%` | `3.19ms` | `SERVER-CORE-BUSY` |
| **5** | **Goose Honk** | `117,488.12` | `8.716` | `0.569` | `8.147` | `101.6%` | `135.5%` | `3.17ms` | `SERVER-CORE-BUSY` |
| **6** | **Bare-C Control** | `115,784.99` | `8.846` | `0.587` | `8.259` | `102.1%` | `137.4%` | `2.69ms` | `SERVER-CORE-BUSY` |
| **6** | **Goose Honk** | `122,347.67` | `8.209` | `0.596` | `7.613` | `101.0%` | `136.1%` | `2.40ms` | `SERVER-CORE-BUSY` |
| **7** | **Bare-C Control** | `117,024.08` | `7.867` | `0.518` | `7.348` | `100.0%` | `136.8%` | `821.79ms` | `SERVER-CORE-BUSY` |
| **7** | **Goose Honk** | `152,283.33` | `6.760` | `0.505` | `6.254` | `103.1%` | `144.5%` | `1.90ms` | `SERVER-CORE-BUSY` |

- **Summary Across Rounds 2–7 (Indicative Only — WSL2)**:

| Metric (Rounds 2–7) | Bare-C Control | Goose Honk (Phase 1) | Goose vs. C |
|---|---:|---:|---:|
| **`req/s` Median (Min – Max)** | `113,076.39` (`98,896.33` – `117,024.08`) | `114,437.62` (`86,138.03` – `152,283.33`) | `101.20%` (indistinguishable) |
| **Total CPU time / req Median (Min – Max)** | `8.880 µs` (`7.867` – `10.177 µs`) | `8.973 µs` (`6.760` – `10.610 µs`) | `+0.093 µs` (`+1.05%`) |
| **User-space CPU time / req Median** | `0.579 µs` (`~6.8%` usr) | `0.621 µs` (`~7.3%` usr) | `+0.042 µs` (`+42 ns/req`) |
| **Kernel (`sys`) CPU time / req Median** | `8.296 µs` (`~93.5%` sys) | `8.366 µs` (`~94.0%` sys) | `+0.070 µs` |
| **Server CPU% Median (`pidstat`)** | `100.2%` (`0` runs client-saturated) | `101.6%` (`0` runs client-saturated) | Both saturate 1 core (`100%`) |
| **`wrk` Client CPU% Median (`pidstat`)** | `135.4%` (of `200%` across 2 cores) | `133.6%` (of `200%` across 2 cores) | Headroom on client cores |

### G.4. Harness Sanity Check: 5-Line `Bun.serve` Hello-World ([bench/bun_sanity.js](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/bench/bun_sanity.js))
- **Label**: **Harness sanity check, not a comparison** (and **indicative only — WSL2**).
- Same pinning (`taskset -c 0` for `Bun.serve`, `taskset -c 4,6` for `wrk -t2 -c64 -d10s --latency`), 1 warmup + 3 measured rounds:
  - **`req/s` Median (Min – Max)**: `68,785.31 req/s` (`67,886.89` – `81,417.91 req/s`)
  - **Total CPU time / req Median**: `13.744 µs/req` (`5.017 µs` user CPU/req + `8.727 µs` sys CPU/req)
  - **Server CPU% Median**: `102.9%` (`38.8%` `%usr`, `64.5%` `%system`)
  - **`wrk` Client CPU% Median**: `74.0%` (of `200%`)
- **Conclusion**: `Bun.serve` saturates the server core (`102.9%` CPU) at `~68.8k req/s` (`~60%` of Goose/C's `~113k–114k req/s`) while `wrk` uses only `74.0%` CPU. This confirms the `wrk` load harness is **not** the bottleneck.

---

## 5. Requirement H: Two-Worker `SO_REUSEPORT` Smoke Test on Separate Physical Cores

- Test script: [test/test_two_workers_reuseport.py](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/test/test_two_workers_reuseport.py).
- Spawned 2 Goose `thread_fn` workers in [src/server_minimal.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/server_minimal.goose), each calling `honk_pin_thread_cpu` and `honk_worker_init` (`SO_REUSEPORT`):
  - **Worker 0**: Pinned to Logical CPU `0` (**Physical Core 0**), verified via `/proc/<pid>/task/<tid>/status` (`Cpus_allowed_list: 0`).
  - **Worker 1**: Pinned to Logical CPU `2` (**Physical Core 1**), verified via `/proc/<pid>/task/<tid>/status` (`Cpus_allowed_list: 2`).
- Sent `200` connections to the shared port on both Release and ASan+UBSan builds:
  - **Release build**: Worker 0 served `88` connections (`tls_accepted_total = 88`), Worker 1 served `112` connections (`tls_accepted_total = 112`), sum = `200`.
  - **ASan+UBSan build**: Worker 0 served `96` connections (`tls_accepted_total = 96`), Worker 1 served `104` connections (`tls_accepted_total = 104`), sum = `200`.
- **Conclusion**: Both workers accept connections on the same port via `SO_REUSEPORT`, connections are distributed across both workers by the kernel, and all worker state is strictly thread-local (`__thread`) with zero shared mutable state. (Per instructions, no scaling conclusions are drawn on this 4-core WSL2 machine.)
