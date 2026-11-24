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
- **Candidates Prototyped & Measured in Step 1a (`wrk -t2 -c64 -d10s`, server on CPU 0, `wrk` on CPUs 4,6, indicative WSL2 numbers)**:
  1. **Candidate (i) — Fixed-capacity per-connection buffer (`u8[..16384]`) inside a struct held in a Goose `slot_pool<ConnBuf>` ([spike_d1.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/spike_d1.goose))**:
     - Correctness: Passed normal, split-`recv()`, and 3x pipelining tests.
     - Peak RAM (`VmHWM`): **34,432 kB** (1.91x higher than Candidates ii/iii because pre-allocating 1024 connection slots touches 16 MB of inline `u8[..16384]` pages on the worker data stack and scatters connection buffers across 16 MB of L3/DRAM).
     - Limitation: Hard fixed capacity `N` per connection (cannot grow dynamically for larger bodies without multiplying idle memory across all connection slots).
  2. **Candidate (ii) — Per-connection buffer on the C side (`__thread`), copied into a Goose per-turn scope (`rx_buf: u8[>..]` via `gs_bld_append`) ([spike_d2.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/spike_d2.goose))**:
     - Correctness: Passed normal, split-`recv()`, and 3x pipelining tests.
     - Peak RAM (`VmHWM`): **18,048 kB**.
     - Trade-off: Copies every request byte once (`memcpy` via `gs_bld_append`) from the C per-connection buffer into Goose's scoped `rx_buf: u8[>..]`, even when a complete request arrives in a single `recv()`.
  3. **Candidate (iii) — Direct-to-Goose-Data-Stack `recv()` via `gs_rref` (`rx_buf.stk->top`) on the fast path + C per-connection partial-tail stash across `epoll` events ([spike_d3.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/spike_d3.goose))**:
     - Correctness: Passed normal, split-`recv()`, and 3x pipelining tests. Also verified with a standalone test ([verify_rref.goose](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/spike/verify_rref.goose)).
     - How it works: On `EPOLLIN`, if the connection has stashed partial bytes from an earlier split `recv()`, C prepends them to Goose's scoped `rx_buf: u8[>..]&` via `gs_bld_append`. Then C calls `recv(fd, rx_buf.stk->top, ...)` **directly into the top of `rx_buf`'s Goose data stack** and advances `rx_buf.stk->top` and `rx_buf.hdr->len`. Goose parses and handles all complete requests in `rx_buf` by slicing `rx_buf` in place (`0` copies). If an incomplete request tail remains at the end of `rx_buf` (`cursor < rx_buf.len`), C stashes only that unparsed tail (`rx_buf[cursor..]`) into a lazily allocated thread-local per-connection buffer for the next `EPOLLIN`. When the Goose turn scope exits, `rx_buf` and `tx_buf` are freed in one pointer store (`GS(gs_sp)->top = base`).
- **Decision**: Choose **Candidate (iii)** on **design grounds**: it avoids copying complete requests (copying only unparsed partial tails across `epoll` events) and avoids the fixed-capacity buffer ceiling and 16 MB pre-allocated pool footprint of Candidate (i).
- **Measurement Note**: In Step 1a, the bare-C control's min–max spread (~30% of its median across 5 sequential runs) was too wide to statistically distinguish the throughput ratios among Candidates (i), (ii), and (iii), so no speed ranking among the three candidates is claimed from Step 1a. Step 1b introduces an interleaved measurement protocol with CPU time per request (`(utime + stime) / requests`) and `pidstat` saturation checks.

## D-004: Strict Thread-Local Isolation (`__thread`) in the C Shim (Amendment B)
- **Context**: Goose `thread_fn` workers share no memory.
- **Decision**: All C shim state (`tls_listen_fd`, `tls_epfd`, `tls_last_sec`, `tls_date_str`, `tls_conns`, `tls_active_conns`, `tls_events`) is declared `static __thread` (thread-local storage). Zero mutable globals or locks exist in the C shim. Programs are always built with `goose build`.

## D-005: Stack Discipline Isolation, Pinned Compiler Commit, and Per-Connection Resource Caps (Requirements E & F)
- **Pinned Goose Compiler Commit**:
  - Commit hash: `2239b92eb2ae0e8f390f98640b09ff57a17698fc` (`v2026.4-78-g2239b92e`)
  - Runtime hash: `68cc5acec0ef`
- **Stack Discipline Isolation ([src/shim/honk_rref.h](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/shim/honk_rref.h))**:
  - All manipulation of `gs_rref`, `gs_rhdr` (`base`, `len`), and `gs_stack` (`top`) is isolated in a single header, [src/shim/honk_rref.h](file:///c:/Users/navap/Desktop/Nav/Personal/Honk/src/shim/honk_rref.h).
  - Compile-time `_Static_assert` checks in `honk_rref.h` verify the exact sizes and field offsets of `gs_stack`, `gs_rhdr`, and `gs_rref` against `goose.h`.
  - Every error/early-exit path in the C shim (`recv() == 0`, `recv() == -1`, `EAGAIN`, peer reset, 431/413/501/400 rejects, and timeouts) explicitly resets or preserves `stk->top == hdr->base + hdr->len` and restores `stk->top` to the baseline on turn exit.
- **Lazy Per-Connection Buffers & Explicit Limits**:
  - Per-worker connection cap: `HONK_MAX_CONNS = 4096` active connections. Any connection accepted when `tls_active_conns >= 4096` (or `fd >= HONK_MAX_FD`) is rejected cleanly via immediate `close(cfd)`.
  - Per-connection `partial_rx` and `pending_tx` pointers in `tls_conns` are `NULL` when idle (lazy allocation via `malloc`/`realloc` only when a partial request tail or unsent `EAGAIN` response tail exists, and `free()`d immediately once drained or when the connection closes).
  - Max header size: `HONK_MAX_HEADER_SIZE = 8192` bytes (exceeding returns `431 Request Header Fields Too Large` and closes the connection).
  - Max body size: `HONK_MAX_BODY_SIZE = 1048576` bytes (1 MiB; `Content-Length > 1048576` returns `413 Payload Too Large` and closes the connection).
  - Max pending tx buffer: `HONK_MAX_PENDING_TX = 1048576` bytes (1 MiB; if a peer never reads responses and queued `pending_tx` would exceed 1 MiB, the connection is closed cleanly).
  - Chunked transfer encoding: `Transfer-Encoding: chunked` returns `501 Not Implemented` and closes the connection in Phase 1.
  - Idle connection & slowloris timeout: Connections tracking `last_active_ms` (and `rx_start_ms` when holding an incomplete header) are swept and closed cleanly if idle longer than `tls_idle_timeout_ms`.

## D-006: Phase 2 Framework Architecture (Stage + Central Emit, Dispatch-as-Code)
- **Context**: Phase 2 adds `Context`/`Request`/`Response`, routing, middleware, and JSON on the locked Phase 1 transport (`honk_conn_read`/`honk_parse_req`/`honk_send`/`honk_conn_finish`). No shim or buffer-design change was needed.
- **Decision**:
  1. **Stage + central emit** (`src/honk_ctx.goose`): handlers stage `(status, content-type, body-slice, extra-headers)` into `Ctx`; a single `emit()` produces all HTTP framing. `Content-Length` is therefore correct by construction; `HEAD` (headers, no body) and `204` (zero length) fall out of one code path. Direct-slice replies (`text`/`bytes` of an existing view) copy zero bytes; constructed bodies (JSON, greetings) serialize once into a per-request `body_buf` and are appended once.
  2. **Dispatch-as-code** (`src/honk_router.goose`): an inline `if/else` graph over `(method, path)` with zero-alloc matchers (`match_1param`, `match_org_repo`) instead of a table of function pointers, so every handler/middleware inlines into the worker loop (verified: no `_g` definitions for `dispatch`, handlers, or middleware in generated C; `header`/`query` stay real calls on cold routes only). `known_path()` (all route shapes, any method) drives `404` vs `405`.
  3. **Middleware as inline fns**: before-chain (`mw_first`, `mw_second`, `mw_auth` guard returning `false` to short-circuit) + after-hook (`mw_after`, runs post-handler, pre-emit). Zero allocations, fully inlined; execution order is observable in `X-MW-1`/`X-MW-2` header order.
  4. **Pure-Goose header/query parsing**: `req.header()` (case-insensitive scan of the raw header block) and `req.query()` (raw `k=v&` scan, no percent-decoding) slice `rx_buf` in place. No `RawReq`/shim extension was required.
  5. **Caller-owned `json::Reader`** (`src/honk_json.goose`): `parse_typed_fields(r: Reader&, scratch, t)` takes a caller-owned reader and out-struct because `read_string` views root at `r.text` (borrow §9.2) and cannot cross a function boundary from a callee-owned reader. Unescaped strings stay zero-copy views into `rx_buf`; only escaped strings decode into per-request `scratch`. Struct fields (not `var` re-binding) hold mixed-root slices.
  6. **Explicit per-request scope per pipelined request**: `body_buf`/`scratch`/`doc`/`decoded` are declared in an inner block inside the `while cursor < rx_buf.len` loop; generated C resets `+3/+4/+5` tops on every loop-back edge and holds the `+2` (body) top in a register with writeback-before-call. Worker uses 11 data stacks (`--stacks`).

## D-007: Hot-Path Exemption for `/` and `/plaintext` (Byte-Compatibility)
- **Context**: The Phase 2 vs bare-C interleave requires `curl -i` byte-identical 115-byte `GET /plaintext` responses, but global middleware stages extra headers (`X-MW-1/2`, `X-Worker`).
- **Decision**: Middleware still RUNS on `/` and `/plaintext` (two slice compares + auth path check) but stages no headers there, keeping responses byte-identical to Phase 1 / the C control while the measured `User CPU/req` honestly includes middleware execution. All other routes carry the injected headers.
