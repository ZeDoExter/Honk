# Architectural & Engineering Decisions (`docs/DECISIONS.md`)

## D-001: Primary Target Environment — WSL2 Linux (Ubuntu 24.04, GCC 13.3.0)
- **Context**: The host machine runs Windows 10/11 with WSL2 (Ubuntu 24.04.4 LTS, Linux kernel `6.6.87.2-microsoft-standard-WSL2`, Intel Core i5-10300H 4 physical cores / 8 threads). The server, test suites, and benchmarks require Linux `epoll`, `SO_REUSEPORT` kernel load-balancing across `thread_fn` workers, `taskset` CPU pinning, and `wrk`.
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
  - Chunked transfer encoding: `Transfer-Encoding: chunked` returns `501 Not Implemented` and closes the connection (transport layer).
  - Idle connection & slowloris timeout: Connections tracking `last_active_ms` (and `rx_start_ms` when holding an incomplete header) are swept and closed cleanly if idle longer than `tls_idle_timeout_ms`.

## D-006: Framework Architecture (Stage + Central Emit, Dispatch-as-Code)
- **Context**: The framework adds `Context`/`Request`/`Response`, routing, middleware, and JSON on the locked transport (`honk_conn_read`/`honk_parse_req`/`honk_send`/`honk_conn_finish`). No shim or buffer-design change was needed.
- **Decision**:
  1. **Stage + central emit** (`src/honk_ctx/honk_ctx.goose`): handlers stage `(status, content-type, body-slice, extra-headers)` into `Ctx`; a single `emit()` produces all HTTP framing. `Content-Length` is therefore correct by construction; `HEAD` (headers, no body) and `204` (zero length) fall out of one code path. Direct-slice replies (`text`/`bytes` of an existing view) copy zero bytes; constructed bodies (JSON, greetings) serialize once into the per-request `c.res` builder and are appended once.
  2. **Dispatch-as-code** (`src/honk_router/honk_router.goose`): an inline `if/else` graph over `(method, path)` with zero-alloc matchers (`match_1param`, `match_org_repo`) instead of a table of function pointers, so every handler/middleware inlines into the worker loop (verified: no `_g` definitions for `dispatch`, handlers, or middleware in generated C; `header`/`query` stay real calls on cold routes only). `known_path()` (all route shapes, any method) drives `404` vs `405`.
  3. **Middleware as inline fns**: before-chain (`mw_first`, `mw_second`, `mw_auth` guard returning `false` to short-circuit) + after-hook (`mw_after`, runs post-handler, pre-emit). Zero allocations, fully inlined; execution order is observable in `X-MW-1`/`X-MW-2` header order.
  4. **Pure-Goose header/query parsing**: `req.header()` (case-insensitive scan of the raw header block) and `req.query()` (raw `k=v&` scan, no percent-decoding) slice `rx_buf` in place. No `RawReq`/shim extension was required.
  5. **Caller-owned `json::Reader`** (`src/honk_json/honk_json.goose`): `parse_typed_fields(r: Reader&, scratch, t)` takes a caller-owned reader and out-struct because `read_string` views root at `r.text` (borrow §9.2) and cannot cross a function boundary from a callee-owned reader. Unescaped strings stay zero-copy views into `rx_buf`; only escaped strings decode into per-request `scratch`. Struct fields (not `var` re-binding) hold mixed-root slices.
  6. **Explicit per-request scope per pipelined request**: `res`/`tmp`/`dom`/`dstr` builders are declared in an inner block inside the `while cursor < rx_buf.len` loop; generated C resets their tops on every loop-back edge and holds the body top in a register with writeback-before-call. Worker uses 11 data stacks (`--stacks`).

## D-007: Hot-Path Exemption for `/` and `/plaintext` (Byte-Compatibility)
- **Context**: The framework-vs-bare-C interleave requires `curl -i` byte-identical 115-byte `GET /plaintext` responses, but global middleware stages extra headers (`X-MW-1/2`, `X-Worker`).
- **Decision**: Middleware still RUNS on `/` and `/plaintext` (two slice compares + auth path check) but stages no headers there, keeping responses byte-identical to the transport baseline / the C control while the measured `User CPU/req` honestly includes middleware execution. All other routes carry the injected headers.

## D-008: Cross-Framework Bench Mode (`HONK_BENCH_MODE`, Worker-TLS Flag)
- **Context**: Cross-framework workloads need exact bodies on standard paths (`/json` -> exactly `{"message":"Hello, World!"}`, `/users/:id` -> `{"id","role"}` + only `X-Frame-Bench`, `POST /users` -> validate -> `201`/`400`), while demo routes on the same paths return different shapes.
- **Decision**: A worker-TLS global set from `argv[5]` selects bench behavior inside the existing dispatch (one predictable branch per affected route). Default mode (`0`) is behavior-identical to the demo app — all transport/framework tests run unmodified with the flag off. Bench mode replaces the decoration middleware chain with the single `mw_bench` W3 hook only.

## D-009: `src/` Package Layout (One Directory Per Framework Module)
- **Context**: Goose packages need a directory of their own: a root file cannot import several modules from one directory (`import honk_net from "../../src"` + `import honk_ctx from "../../src"` is rejected), and there is no re-export, so external apps (and `examples/quickstart/`) could not use a flat `src/*.goose` framework.
- **Decision**: `src/honk_net/`, `src/honk_ctx/`, `src/honk_json/`, `src/honk_router/` — each a Goose package. Roots declare packages (`import honk_net from "./honk_net";`); framework files reference each other bare (`import honk_net;`, resolved from root declarations). Shim C stays in root `.build` files. Verified by full regression (900k turns, transport 9/9, framework 10/10 Release + ASan).

## D-010: Static Files via Kernel `sendfile` (Per-Request Sends)
- **Context**: Pipelined static responses need headers + file bytes in request order, but `tx_buf` batching cannot interleave file bytes between later responses' headers, and builders cannot truncate mid-turn.
- **Decision**: `honk::request` sends each response immediately (per-request `tx` scope): static headers via `honk_send` (queued behind pending bytes), then file bytes via `honk_sendfile_data` with `EPOLLOUT` resume after `pending_tx` drains; at most one active transfer per connection (a pipelined second file under backpressure closes cleanly, documented). `wrk` never pipelines (verified 1:1 send/recv), so batching bought nothing measurable. Security: Goose-side `%`-decode + segment validation (`..`/NUL/backslash rejected), C-side `O_NOFOLLOW` + `O_NONBLOCK` + `fstat` `S_ISREG`, fd closed exactly once on completion/error/timeout/shutdown.

## D-011: Opt-In SQLite (Per-Worker WAL, Main-Thread DDL)
- **Context**: Apps need persistence without a DB server, but non-DB binaries must not pay (size/deps).
- **Decision**: `src/honk_sqlite/honk_sqlite.goose` + `src/shim/honk_sqlite_shim.c`, linked only when the app's `.build` lists them (`c_libs = ["sqlite3"]`; verified via `ldd`). One `NOMUTEX` connection + prepared statements per worker (captured by request blocks), plus zero-copy `sql_json` / `sql_json_one` / `sql_json_one_text` streaming and `insert_text` / `run_int` one-shot helpers; schema DDL runs once in `main` (concurrent DDL can abort with `SQLITE_SCHEMA`, which `busy_timeout` does not cover); `busy_timeout` set before WAL setup; `bind_text` transient by default (`_static` variant documented); column text appended once into request scope; `finalize` → `close` per worker + `db_shutdown()` in main for LSan-clean exit.

## D-012: Single-Import Barrel (`src/honk.goose`) & Zero-Closure `Ctx&` App DSL
- **Context**: Requiring user apps to import 3–4 separate framework directories, spawn `thread_fn` workers for Hello World, branch manually on `ctx.method`/`ctx.path`, and hand-escape JSON strings created unnecessary low-level ceremony for everyday HTTP handlers.
- **Decision**:
  1. **Package barrel (`src/honk.goose`)**: Root apps write a single `import honk from "<honk>/src";` (plus dotted `import honk.honk_sqlite.honk_sqlite;` when opting into SQLite); intra-package modules use dotted imports (`import honk_ctx.honk_ctx;`) inside `namespace honk`.
  2. **No wrapper `App` struct (borrow §9.2)**: `honk::listen(port) { app => … }` passes `Ctx&` directly as `app` and tracks `handled` + `path_matched` on `Ctx` for first-match-wins routing and automatic `405` vs `404` responses. Every route helper (`get`/`post`/`put`/`patch`/`delete`, `get_param`, `get_int`/`patch_int`/`delete_int`, `get2`, `get_wild`/`patch_wild`, `static_dir`), streaming `JWriter` (`app.json()`/`created_json()`), and memoized DOM extractor (`body_str`/`body_int`/`body_bool`/`require_str`) is an `inline fn` monomorphizing directly into the worker loop (`0` closure `_g` definitions in generated C, `~93%` of Bare-C throughput, flat `~1.7 MB` `VmRSS`).

## D-013: Signal-Driven Outbound Drain (`SIGINT`/`SIGTERM`) & Pre-`epoll` `fork()` Scaling (`HONK_WORKERS`)
- **Context**: Production servers under `systemd`/Docker/`Ctrl-C` must drain cleanly on `SIGTERM`/`SIGINT` without exposing a `/__shutdown` HTTP route, and concise `honk::listen` apps need multi-core scaling without rewriting closures into `thread_fn` structs.
- **Decision**:
  1. **Async-signal-safe stop + bounded `EPOLLOUT` drain**: `honk_worker_init` installs `sigaction` handlers (`sa_flags = 0`, waking `epoll_wait` immediately via `EINTR`) with separate `g_sigint_count` and `g_sigterm_flag` flags so `Ctrl-C` + parent-forwarded `SIGTERM` stays graceful while a second `SIGINT` force-exits. `honk_worker_shutdown()` closes `tls_listen_fd` immediately, finishes in-flight `pending_tx`/`sendfile` transfers over `EPOLLOUT` up to `HONK_DRAIN_MS` (`2000 ms`, `0 ms` when idle), and frees all worker allocations for LSan-clean exit.
  2. **Pre-`epoll` `fork()` (`$HONK_WORKERS`, `listen_workers`, `workers`)**: When `workers > 1` (`0`/`"auto"` queries `sched_getaffinity` CPU count, capped at `64`), parent flushes stdio and forks `N - 1` `SO_REUSEPORT` child processes (`worker_id = 0..N-1`, OS-scheduled) *before* creating `epoll`/listen fds, forwards `SIGTERM` to children on shutdown, and `waitpid`s all children in `honk_fork_join()` so destructors and LSan run in every worker.
  3. **SQLite fork-safety guard**: `honk_sqlite_shim.c` tracks live `sqlite3*` handles via an atomic counter in `honk_shim.c`; attempting to `fork()` while any `Db` handle is open aborts immediately with a diagnostic pointing users to call `honk::workers()` / `honk::workers_env()` before `db_open()`.

## D-014: Root Package Sidecar (`honk.build`), Unified Pattern Routing, Overloaded `j.set`, & `BOOLEAN` `sql_json` (`v0.3.0`)
- **Context**: Even with the `v0.2.0` barrel, user apps still carried machine-specific paths in `main.goose` + per-app `main.build` files, memorized separate route method names (`get_param`/`get2`/`get_wild`/`patch_wild`), lacked suffix support on `*_int` routes (e.g. `/todos/:id/toggle`), wrote `j.jbool` due to Goose's `bool` keyword, and hand-coded `0/1` → `bool` loops for SQLite queries.
- **Decision**:
  1. **Zero-sidecar root package (`honk.goose` + `honk.build`) & `sqlite/` sibling package**: Moving the package entry to the repository root with `exclude = ["goose_repo", "test", "examples", "bench", "docs", "sqlite", "src/spike"]` lets Goose compile and cache Honk's C shim automatically — deleting `.build` files from all user apps and enabling native `import honk from "ZeDoExter/Honk@v0.3.0";` alongside portable relative paths in `./honk new`. SQLite moves to `sqlite/honk_sqlite.{goose,build}` so `-lsqlite3` stays strictly opt-in without per-app `.build` files.
  2. **Unified zero-copy pattern matcher (`match_route`)**: `app.get/post/put/patch/delete` and `get_int/post_int/put_int/patch_int/delete_int` share one matcher supporting static paths (`!has_route_meta` folds at compile time), up to 4 `:param` segments with literal suffixes (`app.param("name")` / `app.param(0)`), and trailing `/*` wildcards (`app.tail`). Every route short-circuits immediately once `app.handled` is `true`.
  3. **Type-overloaded `j.set` + `BOOLEAN`-aware `sql_json` + `db_connect` + `honk::arg_port`**: Overloading `j.set(key, val)` across `const u8[:]`, `i64`, `f64`, and `bool` eliminates `jbool` ceremony, while checking `sqlite3_column_decltype` for `BOOL*` in `row_to_json` emits JSON `true`/`false` automatically — shrinking `examples/fullstack_todo/app.goose` from `172` → `110` → `45` lines with zero `.build` sidecar.

## D-015: Zero-Bloat Core DX (`group`, Lifecycle Guards, Nested `JArray`, Validators) & Opt-In `honk_test` (`v0.4.0`)
- **Context**: Closing the everyday DX gap with frameworks like Express/Deno/Hono required nestable route prefixes, one-line CORS/Bearer/timing/JSON-error hooks, nested JSON objects/arrays, field-named input validation, and zero-socket unit tests — without bloating Honk's `~150 KiB` baseline binary.
- **Decision**:
  1. **Zero-alloc `app.group(prefix)`**: Slices `app.path` in place using `saved[..1]` (`"/"`) vs `saved[p.len..]` so both branches share the `rx_buf` borrow root (§9.2), restoring `app.path` on exit and skipping non-matching subtrees in one branch.
  2. **`inline fn` lifecycle & validation (compile-away when unused)**: `cors()`, `bearer()`, `json_errors()`, `server_timing()` (`CLOCK_MONOTONIC` `honk_now_ns()` called only when armed), `after()`, nested `JWriter::obj`/`arr` + `JArray` (`json_list`), and field-named `require_str_len`/`require_int`/`require_int_range`/`require_bool` live as `inline fn`s in `honk_app.goose`, adding `0` bytes to apps that do not call them.
  3. **Opt-in `src/honk_test/honk_test.goose` (`honk::tester()`)**: Stores last status, `Content-Type`, headers, and body in fixed value arrays inside `Tester` (zero slice fields, avoiding §9.2 borrow re-binding across repeated test calls) and runs routes directly in memory without sockets; excluded from production binaries unless explicitly imported.

## D-016: Opt-In Pure-Goose `honk_auth` (`HS256` JWT + Signed Cookies), Lazy Rate Limiter, & `ETag` / `embed` Static (`v0.5.0`)
- **Context**: Production APIs and SPAs need stateless auth (`HS256` JWT + tamper-proof cookies), per-IP rate limiting (`429`), conditional static caching (`ETag` / `304`), and single-binary asset embedding — without adding OpenSSL or growing minimal binaries.
- **Decision**:
  1. **Opt-in pure-Goose `src/honk_auth/honk_auth.goose`**: Implements FIPS 180-4 SHA-256, RFC 2104 HMAC-SHA256, RFC 4648 Base64URL, constant-time `ct_eq`, `HS256` JWT (`alg == "HS256"` enforced before payload claims, `exp`/`nbf` validated), and cookie-name-bound signed cookies (`name=val` MAC input prevents cross-cookie swap attacks). Binaries not importing `honk_auth` pay `0` bytes.
  2. **Peer IP + lazy thread-local rate table (`honk_shim.c`)**: `accept4` records `ntohl(sin_addr)` in `honk_conn_t`; `honk_rate_allow` allocates its 2048-slot table lazily on first call and frees it in `honk_worker_shutdown()` (zero idle RAM, LSan-clean).
  3. **`ETag` / `304` + single-binary `app.embed`**: `serve_rel_cached` emits `W/"<size>-<mtime>"` and short-circuits matching `If-None-Match` with `304 Not Modified` before `sendfile`; `app.embed` pairs with Goose's compile-time `embed_file(...)` to serve `.rodata` assets with deterministic FNV-1a `ETag`s.

## D-017: Two-Pass Inbound Chunked Decoding, Flat-RSS `stream`/`sse`, & Zero-Copy Forms/Multipart (`v0.6.0`)
- **Context**: Real-world clients, proxies, AI/event streams, and HTML file uploads require inbound `Transfer-Encoding: chunked` requests, outbound HTTP/1.1 chunked streaming + Server-Sent Events (`SSE`), and `x-www-form-urlencoded` / `multipart/form-data` parsing — without violating Honk's stateless split-`recv()` design or growing binary size / per-connection memory.
- **Decision**:
  1. **Non-destructive 2-pass `decode_chunked_body` (`honk_shim.c`)**: Pass 1 validates chunk hex sizes, `HONK_MAX_BODY_SIZE` (`413`), `16 KiB` framing-overhead cap (`400`), and optional trailers *without mutating `rx_buf`*, so incomplete (`-2`) split `recv()` turns stash intact wire bytes in `partial_rx` and pipelined requests past `0\r\n\r\n` remain untouched. Pass 2 compacts chunk payloads in-place into `rx_buf[pret .. pret + decoded_len]` while `RawReq.consumed` advances by `pret + wire_len`. Requests carrying both `Content-Length` and `Transfer-Encoding` are rejected with `400 Bad Request` (RFC 9112 §6.1 smuggling defense); non-`chunked` transfer codings still return `501`.
  2. **Per-chunk stack reset in `app.stream` & `app.sse` (`honk_app.goose`)**: Each `s.write` / `ev.send` / `ev.event` formats its chunk frame inside a function-scoped `u8[>..]` that pops back to `0` on `honk_send` return, keeping worker RSS flat even across unbounded SSE streams while omitting `Content-Length` on the wire (`HEAD` emits headers only) and capturing concatenated payloads in `honk::tester()` (`fd < 0`).
  3. **Zero-copy RFC 7578 `multipart/form-data` + `form` (`honk_ctx.goose`)**: `each_part` / `multipart_file` / `multipart_part` slice part headers and binary payloads directly out of `c.body` (`0` copies of uploaded file bytes), strip directory components from `filename` per RFC 7578 §4.2, and integrate with `app.form(key)` / `require_form(key)` alongside shared `kv_lookup` + `url_decode` for `application/x-www-form-urlencoded`.

## D-018: Opt-In RFC 6455 WebSockets (`honk_ws`) & OpenAPI 3.1.0 + Docs UI (`honk_openapi`) (`v0.7.0`)
- **Context**: Full-featured backends need bidirectional WebSockets and self-hosted OpenAPI 3.1 specs + interactive API docs without adding external C libraries or growing baseline Honk binaries.
- **Decision**:
  1. **Opt-in pure-Goose `src/honk_ws/honk_ws.goose` + poll-sliced shim helpers**: Implements FIPS 180-4 SHA-1 + Base64 `Sec-WebSocket-Accept` handshake (`101` / `426` / `400`), enforces RFC 6455 §5.1 client frame masking (`1002`), auto-replies `Pong` to `Ping`, reassembles fragmented messages (`<= 1 MiB`, else `1009`), and resets `msg_buf` via `honk_buf_reset` on every message so long-lived WebSockets run at flat RSS while checking `honk_should_stop()` every `100 ms` for instant `SIGINT`/`SIGTERM` shutdown.
  2. **Opt-in `src/honk_openapi/honk_openapi.goose`**: `app.openapi(route, title, version) { spec => … }` translates Honk `:param`/`*` patterns to OpenAPI `{param}` templates + typed path parameters, merges same-path methods into valid single-key JSON objects, and pairs with `app.docs(route, spec_url, title)` for zero-dependency interactive Scalar docs (`0` bytes in apps not importing it).

## D-019: Toolchain Reproducibility — Pin-by-Hash, Fingerprints, No Vendor Blob
- **Context**: Honk builds on a Goose compiler pinned to commit `2239b92eb` (ahead of upstream tag `v2026.4`); a silent toolchain drift would invalidate every benchmark and sanitizer gate.
- **Decision**:
  1. **Pin-by-hash, not vendoring**: `goose_repo/` (119 MB with build outputs, 28 MB source-only) stays git-ignored and is cloned + checked out to `PINNED_GOOSE` by `./honk setup`; committing the blob would bloat the repo for zero gain.
  2. **Enforcement + audit trail**: `./honk doctor` fails when the checkout drifts from the pin (and warns on a dirty tree); every `./honk build` stamps a `<binary>.build-info` sidecar (goose version/commit, cc, honk HEAD, asan, timestamp).
  3. **CI is the clean room**: `.github/workflows/ci.yml` runs `setup` + full `./honk test` from scratch on every push; a green CI run is the reproducibility proof.
  4. **Upstream tracking**: re-pin only onto a newer upstream *tag* (currently ahead of `v2026.4`); until one lands, the pin + fingerprint above is the policy.

## D-020: Non-Blocking WebSocket Turns (Core Pump + Opt-In Dispatch)
- **Context**: Blocking `each_msg` loops pinned a whole worker per connection; idle sockets starved HTTP on small machines.
- **Decision**: frame pump in core (`honk_serve`: ~48B Goose-global slots + C lazy partial/message/aux buffers, C slot index as source of truth, fd-reuse revalidation; a 2 KiB-per-slot Goose pool measured +10 MB RSS from thread-spawn copies and was rejected), message turns re-dispatch the app block as `WSMSG` ctx (concrete path re-matched via preserved `base_path`, params/user/authed restored, bearer bypassed, rate limits enforced per message), replies via EAGAIN-safe `honk_send`. `app.ws(route) { msg, ws => … }` per-message callback; handshake claims a slot (503 past 1024/worker). Blocking `recv_into`/`each_msg`/`honk_ws_{recv_exact,send_all,unmask}` removed. `stream()`/`sse()` stay blocking by design (server-push has no event source in Honk's model; size workers per GUIDE).

## D-021: Opt-In Dynamic Gzip (`gzip/`, System zlib)
- **Context**: precompressed sidecars cover static files with zero per-request CPU, but dynamic bodies (JSON APIs, rendered HTML) shipped uncompressed; a hot-path middleware would tax every response for a feature most routes skip.
- **Decision**: explicit per-route `app.json_gz`/`text_gz`/`html_gz` (threshold + `Accept-Encoding` token match with `q=0` honored, else identity), one-shot `deflateInit2` level 6 in `src/shim/honk_gzip_shim.c` via system `-lz` (same opt-in contract as `sqlite/`: `0` bytes + no extra link unless imported). Bodies always materialize into `app.res` — Goose §9.2 regionck rejects staging caller-rooted slices across the helper boundary, so the identity path pays one copy (sound for handler-local buffers by construction).
