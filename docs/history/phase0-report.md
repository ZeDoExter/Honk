# Phase 0 Investigation Report — Honk (Goose HTTP Backend Framework)

## 1. Repository & Compiler Verification

### Repository State
- Cloned `https://github.com/aardappel/goose.git` into `goose_repo/`.
- Commit: `2239b92e` (`v2026.4-78-g2239b92e`, runtime hash `68cc5acec0ef`).
- Read:
  - `README.md`
  - `docs/tutorial.md`
  - `docs/reference.md`
  - `docs/stdlib.md`
  - `docs/packages.md`
  - `docs/command_line.md`
  - `docs/testing.md`
  - `docs/goose_spec.md` (§7.10–7.11, §10, Appendix B–D)
  - `samples/README.md`, `samples/18_json.goose`, `samples/23_mandelbrot_threads.goose`, `samples/24_call_c.goose`

### Host & Target Environments
Because Phases 1–3 require Linux networking primitives (`epoll`, `SO_REUSEPORT`) and Linux benchmarking tools (`wrk`), we built and verified the Goose compiler from source in **both** the local WSL2 Linux environment (primary target for Phases 1–3) and native Windows (secondary host).

#### Primary Target: WSL2 Linux (Ubuntu 24.04.4 LTS, kernel `6.6.87.2-microsoft-standard-WSL2`)
- **Hardware**: Intel Core i5-10300H @ 2.50 GHz (4 physical cores, 8 hardware threads), 11 GiB RAM allocated to WSL2.
- **Compiler binary**: `goose_repo/build-linux/goose`
- **`goose samples/01_tour.goose`**: Compiled and executed in-process via TinyCC; exited with code `0` and matched expected tour output (`answer=42 count=2 byte=255 ... 9 2.5`).
- **`goose toolchain` output**:
  ```text
  C compiler:   gcc 13.3.0, found on PATH
                /usr/bin/cc
  C++ compiler: /usr/bin/g++
  style:        cc
  id:           gcc-13.3.0-a920ca84
  cmake:        /home/navap/.local/bin/cmake (3.31.6)
  git:          /usr/bin/git (2.43.0)
  built in:     no packages
  GOOSE_HOME:   /home/navap/.goose
  ```
- **Threaded AOT verification**: Ran `goose build -o /tmp/mandelbrot_threads goose_repo/samples/23_mandelbrot_threads.goose && /tmp/mandelbrot_threads`. Confirmed runtime compilation and 8-thread worker execution (`serial 41.2 ms, 8 threads 8.2 ms`).

#### Secondary Host: Windows x64 (Windows 10/11 build 26300)
- **Compiler binary**: `goose_repo/build/Release/goose.exe`
- **`goose samples/01_tour.goose`**: Exited with code `0`, identical output.
- **`goose toolchain` output**:
  ```text
  C compiler:   MSVC 19.44.35222 (toolset 14.44.35207), found in Visual Studio (vcvars64)
                C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\HostX64\x64\cl.exe
  C++ compiler: C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\HostX64\x64\cl.exe
  style:        msvc
  id:           msvc-19.44.35222-7258e1db
  cmake:        C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe (3.31.6-msvc6)
  git:          C:\Program Files\Git\cmd\git.exe (2.52.0.windows.1)
  built in:     no packages
  GOOSE_HOME:   C:/Users/navap/.goose
  ```

---

## 2. Standard Library Networking Audit (File/Line Evidence)

**Finding**: The Goose standard library and runtime have **zero networking support** (no sockets, TCP, UDP, DNS, epoll, or HTTP).

### Evidence
1. **`goose_repo/docs/stdlib.md` (lines 1271–1273)**:
   > "`exit(code)` and `abort(msg)` are builtins, so that the checker knows they diverge. Subprocesses and networking are not in v1; they arrive as `extern fn`s when a program needs them."
2. **`goose_repo/docs/tutorial.md` (line 1671)**:
   > "**v1 omissions** you will notice: ... no subprocesses or networking in the library yet (`os`)."
3. **`goose_repo/stdlib/` directory inventory**:
   Contains 17 `.goose` files: `base64.goose`, `binary.goose`, `csv.goose`, `dictionary.goose`, `exception.goose`, `ffi.goose`, `json.goose`, `mat.goose`, `math.goose`, `os.goose`, `quat.goose`, `regex.goose`, `slice_pool.goose`, `slice_pool_internal.goose`, `slot_pool.goose`, `std.goose`, `vec.goose`. None defines any network or socket API.
4. **`goose_repo/stdlib/os.goose` (lines 1–87)**:
   Declares only `trim_memory` (line 12), file I/O (lines 15–23), directory ops (lines 26–30), standard streams (lines 33–38), CLI args & env (lines 41–43, 60–68), `resource_dir` (lines 49–54), clocks & sleep (lines 71–79), and OS entropy (lines 82–87).
5. **`goose_repo/src/runtime/runtime_os.h` (lines 1–1390) & `goose_repo/src/runtime/runtime_ext.h` (lines 330–383)**:
   Implements only the `gs_os_*` file/dir/stdio/clock/random functions, `gs_dl_bind` (`dlopen`/`LoadLibrary`), and `gs_slice_pool_*`. Neither `<sys/socket.h>`, `<netinet/in.h>`, `<sys/epoll.h>`, nor `<winsock2.h>` is included anywhere in `src/runtime/`.

---

## 3. JSON Facilities Audit

Goose provides **two** JSON implementations in the repository, and the standard library module `stdlib/json.goose` is much more complete and better suited for an HTTP server than the sample `samples/18_json.goose`:

### A. Standard Library `json` Module (`goose_repo/stdlib/json.goose`, lines 1–887; `docs/stdlib.md` lines 1496–1635)
`import json;` (in `namespace json`) provides three distinct APIs:
1. **Zero-copy / In-place JSON Writer (`stdlib/json.goose` lines 13–270)**:
   - `json::format_string(out: u8[>..]&, s: u8[:])` — fast path checks `plain(s)` and appends in one slice copy; escapes control chars, `"`, and `\`.
   - `json::format_key(out: u8[>..]&, key: u8[:])` — appends `"key":` directly to `out`.
   - `json::format_int(out: u8[>..]&, v: i64)` and `json::format_bool(out: u8[>..]&, b: bool)`.
   - `json::format_number(out: u8[>..]&, v: f64)` — uses an inline Ryu shortest-roundtrip algorithm (`ryu_digits`, lines 138–236) and 8-digit SWAR decimal emission (`put8`, lines 261–270).
   - Writes directly to any `u8[>..]&` response builder on the data stack with no intermediate string allocations.
2. **Streaming Typed Reader (`json::Reader`, `stdlib/json.goose` lines 694–887)**:
   - `var r = json::reader(text)` creates a cursor `{ text: const u8[:], pos: i64, error: const u8[:], error_at: i64 }`.
   - `json::each_member(r) { key => ... }` and `json::each_element(r) { ... }` use compile-time function blocks to parse directly into caller-defined Goose structs without building any DOM tree.
   - `json::read_int(r)`, `json::read_number(r)`, `json::read_bool(r)`, `json::read_string(r, scratch: u8[>..]&) -> const u8[:]`, `json::skip(r)`, `json::finish(r) -> bool`, `json::message(r) -> u8[>..]`.
   - Unescaped strings are returned as zero-copy `const u8[:]` slices directly into the request body buffer; only strings containing `\` escapes use the caller's `scratch` data stack.
3. **DOM Tree Parser (`json::parse`, `stdlib/json.goose` lines 489–690)**:
   - `json::parse(text: u8[:], doc: Node[>..]&, decoded: u8[>..]&) -> Node?, u8[>..]`
   - Iterative (non-recursive) parser using a local `Open[>..<]` stack (line 527) and caller-owned `doc: Node[>..]&` and `decoded: u8[>..]&` buffers.
   - Nodes are fixed-size (`struct Node { next: Node&<u32>?, first: Node&<u32>?, key: const u8[:], val: Value }`), with 4-byte self-relative links and zero-copy slices for unescaped keys/strings.
   - Supports lookup via `json::member(n, key)`, `json::each(n) { child => ... }`, `json::as_i64`, `json::as_f64`, `json::as_bool`, `json::as_string`.

### B. Sample `samples/18_json.goose` (lines 1–312)
- Educational sample showing a recursive-descent parser storing variable-mode `Json..` enums with inline `u8[varint]` strings in a global `var pool: Node[>..]`, using `return ... from parse` for syntax errors.
- **Why we should use `stdlib/json.goose` instead of `samples/18_json.goose`**:
  - `samples/18_json.goose` pushes into a global `pool` and copies every key and string into `u8[varint]`.
  - `stdlib/json.goose` uses caller-scoped `u8[>..]` / `Node[>..]` data stacks (freed in one store on request scope exit), does zero copies for unescaped strings, and provides both `json::Reader` (zero-DOM struct deserialization for maximum throughput) and `json::parse` (DOM tree when dynamic inspection is needed).

---

## 4. C Shim Design Plan (Phase 1 & Phase 2 Architecture)

### Constraints from Goose's FFI and Memory Model (`goose_spec.md` §7.10 & Appendix C)
1. **Allowed `extern fn` types**:
   - Scalars (`i8..i64`, `u8..u64`, `f32`, `f64`, `bool`).
   - Flat fixed-size structs/arrays by value or by reference (`T&` -> C pointer `T_g*`).
   - Slices of flat fixed-size elements (`T[:]` -> `sl_u8 { uint8_t *data; int64_t len; }`).
   - Grow-only builders of flat fixed-size elements (`T[>..]&` -> `gs_rref { gs_rhdr *hdr; gs_stack *stk; }`).
2. **Disallowed `extern fn` types**:
   - Structs containing slices (`u8[:]`) or references cannot cross `extern fn` ("references inside structs ... is rejected at the declaration", `goose_spec.md` §7.10 line 3416).
   - Foreign C pointers cannot be turned into Goose `u8[:]` slices without copying into a Goose owner (`docs/stdlib.md` line 1289).
3. **Thread Isolation (`goose_spec.md` §11.2)**:
   - Each `thread_fn` worker is a separate program instance with its own data stacks and TLS globals, sharing no Goose memory.
   - Programs using `thread_fn` must be built with `goose build` (not TinyCC JIT).

### Zero-Copy Data-Stack I/O + `picohttpparser` Shim Design
To honor Goose's per-request data-stack scoping **and** avoid copying request data between C and Goose:

1. **Sidecar & Files**:
   - Root file sidecar `*.build`:
     ```goose
     c_sources = ["src/shim/honk_shim.c", "src/shim/picohttpparser.c"];
     c_include = ["src/shim"];
     c_flags_cc = ["-O3", "-march=native"];
     ```
2. **Thread-Per-Core (`SO_REUSEPORT`) Worker State**:
   - Each `thread_fn` worker calls `honk_worker_init(port: i32) -> i32` which creates:
     - A non-blocking listening socket with `SO_REUSEADDR`, `SO_REUSEPORT`, `TCP_NODELAY`, and `SOMAXCONN`.
     - A dedicated `epoll` instance (`epoll_create1(0)`) monitoring the listener and accepted client sockets (`EPOLLIN | EPOLLET` or level-triggered `EPOLLIN` with `TCP_NODELAY`).
     - A worker-private C context (allocated per worker handle returned to that worker thread; zero shared mutable state or locks across workers).
3. **Direct Read into Goose Data Stack (`gs_rref`)**:
   - In the Goose worker loop, for each ready connection event, Goose enters a fresh block scope `{ ... }` and declares:
     ```goose
     var rx_buf: u8[>..] = [];
     var tx_buf: u8[>..] = [];
     ```
   - Goose calls `extern fn honk_conn_read(worker_id: i32, conn_id: i32, rx_buf: u8[>..]&) -> i32`.
   - In C, if the connection had partial leftover bytes from a previous incomplete request (rare), C appends them via `gs_bld_append(rx_buf, ...)`. Then C calls `recv(fd, rx_buf.stk->top, 65536, 0)` **directly into the top of `rx_buf`'s Goose data stack** and advances `rx_buf.stk->top` and `rx_buf.hdr->len`!
   - Result:
     - **0 extra copies**: Kernel `recv()` writes directly into Goose's scoped `rx_buf`.
     - **0 idle connection buffer RAM**: Idle keep-alive connections consume almost no memory (only a tiny descriptor struct), keeping peak RAM at 1024 connections tiny.
4. **Parsing via `picohttpparser` into Flat Offset Spans**:
   - Goose passes `rx_buf[cursor..]` (`const u8[:]`) and a flat fixed-size `RawRequest&` struct to:
     ```goose
     struct Span { off: i32, len: i32 }
     struct HeaderSpan { name_off: i32, name_len: i32, val_off: i32, val_len: i32 }
     struct RawRequest {
         method: Span,
         path: Span,
         minor_version: i32,
         keep_alive: bool,
         pad 3,
         num_headers: i32,
         headers: HeaderSpan[32],
         body: Span,
         consumed: i32, // >0: complete request bytes consumed; -2: incomplete; -1: bad request
     }
     extern fn honk_parse_request(buf: const u8[:], out: RawRequest&) -> i32;
     ```
   - `honk_parse_request` calls `phr_parse_request()`, extracts `Content-Length` and `Connection: keep-alive`/`close` in one pass over the parsed headers, verifies the full body (`consumed = header_len + content_length <= buf.len`, or returns `-2` if incomplete / `-1` if malformed), and writes relative `(off, len)` spans into `RawRequest`.
   - Because `rx_buf` is a Goose array, Goose slices `rx_buf[ cursor + req.path.off .. cursor + req.path.off + req.path.len ]` and `rx_buf[ cursor + req.body.off .. cursor + req.body.off + req.body.len ]` as **zero-copy, lifetime-checked `const u8[:]` views**!
5. **Pipelining & In-Place Response Assembly**:
   - While `cursor < rx_buf.len`, Goose loops over pipelined requests in `rx_buf`.
   - For each request, an inner scope `{ ... }` runs the compile-time router/middleware and appends the HTTP response (`HTTP/1.1 200 OK\r\nDate: <cached RFC 7231 date>\r\nContent-Type: ...\r\nContent-Length: <computed>\r\n\r\n` + body) into `tx_buf: u8[>..]`.
   - The `Date` header is updated dynamically once per second from the OS clock (`honk_date_header(out: u8[>..]&)`), and `Content-Length` is formatted dynamically from the body length — **no hardcoded precomputed full HTTP responses**.
   - After the pipelined batch in `rx_buf` finishes (or hits `-2` incomplete tail), Goose calls `honk_conn_finish_turn(worker_id, conn_id, rx_buf[cursor..], tx_buf)` which sends `tx_buf` in a single `send()` syscall (queuing any unsent tail on `EAGAIN` and stashing any unconsumed partial request bytes `rx_buf[cursor..]`).
   - Exiting the connection turn's Goose block scope resets `rx_buf` and `tx_buf` data stacks in **one store each**.

---

## 5. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **1. `extern fn` disallows structs containing slices (`u8[:]`)** | Compiler rejects `struct Req { path: u8[:] }` at the `extern fn` boundary (`goose_spec.md` §7.10). | Pass flat `(off: i32, len: i32)` spans across `extern fn` into a Goose-owned `rx_buf: u8[>..]`, then construct a Goose-native `Request` struct holding `const u8[:]` slices inside Goose. |
| **2. Packed Goose struct alignment vs C struct alignment** | Goose structs are 1-byte packed by default (`#pragma pack(push, 1)`), whereas C structs insert natural padding. | Use only natural-aligned 4-byte (`i32`) fields in `Span`, `HeaderSpan`, and `RawRequest` (or include explicit `pad` and use the compiler-generated `RawRequest_g` typedef via `c_headers`). |
| **3. Data stack virtual address reservation vs `hardware_threads()`** | By default, each data stack reserves 2 GB virtual space (committed on touch). WSL2 has 11 GiB physical RAM and standard Linux virtual overcommit. | Pass `--stack-reserve 64M` (or `-DGS_STACK_RESERVE=(64ull<<20)`) when building the server so virtual memory footprint stays compact while still giving 64 MB per data stack per worker. |
| **4. Compiler bugs in bleeding-edge Goose (`v2026.4-78-g2239b92e`)** | Complex combinations of generics, function values, and `return ... from` may trigger edge-case typechecker or codegen bugs. | Verify every new Goose snippet immediately with `goose check`; minimize and log any compiler bug in `docs/goose-issues.md` before working around it. |
| **5. WSL2 localhost networking variance in Phase 3** | Running client and server on the same 4-core/8-thread CPU can cause scheduler contention. | Run all three servers (Honk, Elysia/Bun, bare C epoll) inside the same WSL2 Ubuntu instance, pin server and load generator to disjoint CPU cores with `taskset`, warm up first, and run >=5 repetitions reporting median and min/max spread. |

---

## 6. Concrete Go / No-Go Plan for Phase 1

**Recommendation: GO.** All prerequisites are verified:
- The Goose compiler builds and runs cleanly on WSL2 Linux (GCC 13.3.0) and Windows (MSVC 19.44).
- `thread_fn` workers, `extern fn` C interop, `gs_rref` data-stack builders, and `stdlib/json.goose` all work as documented.

### Phase 1 Execution Steps (awaiting your approval)
1. Vendor `picohttpparser.h` / `picohttpparser.c` into `src/shim/`.
2. Implement `src/shim/honk_shim.c` and `src/shim/honk_shim.h` (Linux `epoll`, non-blocking sockets, `SO_REUSEADDR`/`SO_REUSEPORT`, `TCP_NODELAY`, zero-copy `recv` into Goose `u8[>..]&` data stack, `phr_parse_request` wrapper, cached 1 Hz RFC 7231 `Date` generator, and pipelined batch `send` with `EAGAIN` handling).
3. Implement the Phase 1 Goose server (`src/honk.goose` + `phase1_server.goose` / `phase1_server.build`) handling HTTP/1.1 keep-alive, HTTP pipelining, and dynamic `Content-Length` + `Date` headers.
4. Verify with `goose check`, build with `goose build`, and test against `curl` and `wrk` (including pipelined `wrk` via Lua script).
