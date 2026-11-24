# Architectural & Engineering Decisions (`docs/DECISIONS.md`)

## D-001: Primary Target Environment — WSL2 Linux (Ubuntu 24.04, GCC 13.3.0)
- **Context**: The host machine runs Windows 10/11 with WSL2 (Ubuntu 24.04.4 LTS, Linux kernel `6.6.87.2-microsoft-standard-WSL2`, Intel Core i5-10300H 4 physical cores / 8 threads). Phases 1–3 require Linux `epoll`, `SO_REUSEPORT` kernel load-balancing across `thread_fn` workers, `taskset` CPU pinning, and `wrk`.
- **Decision**: Build and run the Honk server, C epoll shim, test suite, and benchmarks natively inside WSL2 Linux using the Linux Goose compiler (`goose_repo/build-linux/goose` + GCC 13.3.0).
- **Physical Core Mapping (`lscpu -e`)**:
  - Physical Core 0: Logical CPUs `0, 1`
  - Physical Core 1: Logical CPUs `2, 3`
  - Physical Core 2: Logical CPUs `4, 5`
  - Physical Core 3: Logical CPUs `6, 7`
  - For single-worker benchmarks (Step 1a), the server is pinned to CPU `0` (Physical Core 0) and `wrk -t2` is pinned to CPUs `4,6` (Physical Cores 2 and 3), avoiding any shared physical core or sibling hyperthread contention. All WSL2 numbers are labeled **indicative only**.

## D-002: Use Standard Library `json` (`stdlib/json.goose`) Instead of `samples/18_json.goose`
- **Context**: Goose ships both an educational JSON sample (`samples/18_json.goose`) and a production standard library module (`stdlib/json.goose`).
- **Decision**: Use `import json;` from the standard library (`stdlib/json.goose`).
- **Why**:
  1. `samples/18_json.goose` uses a global `var pool: Node[>..]` and copies all keys/strings into `u8[varint]`.
  2. `stdlib/json.goose` uses caller-owned per-request data-stack buffers (`doc: Node[>..]&`, `decoded: u8[>..]&`, or `scratch: u8[>..]&`), keeps unescaped strings/keys as zero-copy `const u8[:]` slices into the HTTP request buffer, provides a zero-DOM typed streaming reader (`json::Reader`), and formats numbers in-place with an inline Ryu/SWAR implementation (`json::format_*`).

## D-003: Per-Connection Buffer Persistence Across `epoll` Events (Amendment A & Step 1a Spike)
- **Context**: Goose data stacks allow at most one live resizable value per stack, on top, freed at scope exit. A buffer that must survive between `epoll` events (e.g., an HTTP request split across several `recv()` calls, slow clients, or large bodies, as well as partial `send()` hitting `EAGAIN`) cannot live solely in a per-iteration data-stack scope.
- **Candidates Prototyped & Measured in Step 1a (`wrk -t2 -c64 -d10s`, 5 runs after warmup, server on CPU 0, `wrk` on CPUs 4,6, indicative WSL2 numbers)**:
  1. **Candidate (i) — Fixed-capacity per-connection buffer (`u8[..16384]`) inside a struct held in a Goose `slot_pool<ConnBuf>` ([spike_d1.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/spike_d1.goose))**:
     - Correctness: Passed normal, split-`recv()`, and 3x pipelining tests.
     - Throughput: **99,676.24 req/s** median (spread `82,242.78` – `131,711.25` req/s; **78.95%** of bare-C control).
     - Peak RAM (`VmHWM`): **34,432 kB** (1.91x higher than Candidates ii/iii because pre-allocating 1024 connection slots touches 16 MB of inline `u8[..16384]` pages on the worker data stack and scatters connection buffers across 16 MB of L3/DRAM).
     - Limitation: Hard fixed capacity `N` per connection (cannot grow dynamically for larger bodies without multiplying idle memory across all connection slots).
  2. **Candidate (ii) — Per-connection buffer on the C side (`__thread`), copied into a Goose per-turn scope (`rx_buf: u8[>..]` via `gs_bld_append`) ([spike_d2.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/spike_d2.goose))**:
     - Correctness: Passed normal, split-`recv()`, and 3x pipelining tests.
     - Throughput: **118,791.23 req/s** median (spread `91,184.53` – `145,425.43` req/s; **94.09%** of bare-C control).
     - Peak RAM (`VmHWM`): **18,048 kB**.
     - Trade-off: Copies request bytes once (`memcpy` via `gs_bld_append`) from the C per-connection buffer into Goose's scoped `rx_buf: u8[>..]`.
  3. **Candidate (iii) — Direct-to-Goose-Data-Stack `recv()` via `gs_rref` (`rx_buf.stk->top`) on the fast path + C per-connection partial-tail stash across `epoll` events ([spike_d3.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/spike_d3.goose))**:
     - Correctness: Passed normal, split-`recv()`, and 3x pipelining tests. Also verified with a standalone test ([verify_rref.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/verify_rref.goose)).
     - How it works: On `EPOLLIN`, if the connection has stashed partial bytes from an earlier split `recv()`, C prepends them to Goose's scoped `rx_buf: u8[>..]&` via `gs_bld_append`. Then C calls `recv(fd, rx_buf.stk->top, ...)` **directly into the top of `rx_buf`'s Goose data stack** and advances `rx_buf.stk->top` and `rx_buf.hdr->len`. Goose parses and handles all complete requests in `rx_buf` by slicing `rx_buf` in place (`0` copies). If an incomplete request tail remains at the end of `rx_buf` (`cursor < rx_buf.len`), C stashes only that unparsed tail (`rx_buf[cursor..]`) into the connection's thread-local C state for the next `EPOLLIN`. When the Goose turn scope exits, `rx_buf` and `tx_buf` are freed in one pointer store (`GS(gs_sp)->top = base`).
     - Throughput: **126,254.78 req/s** median (spread `113,813.21` – `130,257.41` req/s; **100.00%** of the bare-C control's `126,253.88` req/s median!).
     - Peak RAM (`VmHWM`): **18,048 kB** (and in Step 1b, allocating each connection's partial-rx / pending-tx buffer lazily on demand in C will reduce idle per-connection memory to ~32 bytes).
- **Decision**: Choose **Candidate (iii)** (Direct-to-`gs_rref` data-stack `recv()` fast path + thread-local per-connection partial-rx / pending-tx buffers in C for split `recv()` and partial `send()` `EAGAIN`).
- **Why**: It wins on both correctness (handles arbitrary split `recv()` chunks, pipelining, and large bodies up to `MAX_BODY_SIZE` without fixed-array truncation) and performance (**100.00%** of bare-C control throughput, tightest spread, zero copies on complete requests, and L1-hot data-stack reuse across all connections).

## D-004: Strict Thread-Local Isolation (`__thread`) in the C Shim (Amendment B)
- **Context**: Goose `thread_fn` workers share no memory.
- **Decision**: All C shim state (`tls_listen_fd`, `tls_epfd`, `tls_last_sec`, `tls_date_str`, `tls_conns`, `tls_events`) is declared `static __thread` (thread-local storage). Zero mutable globals or locks exist in the C shim. Programs are always built with `goose build`.
