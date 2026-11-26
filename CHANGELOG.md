# Changelog

## v1.0.1 — WS Memory Fix, Unix Bind Order, Fresh Benchmarks

- Fixed `+10 MB` RSS regression from v1.0.0's 2 KiB-per-slot WS pool
  (thread-spawn copies): slots are back to ~48B with frame tails stashed in
  the existing `partial_rx` — idle RSS `2.1 MB` again, verified flat.
- Fixed Unix-socket `EADDRINUSE` race when `workers(n)` forked before the
  bind spec was set: new `honk::listen_at_workers()` orders bind-then-fork,
  wrong order aborts loudly, and the suite proves both workers share accept.
- Refreshed 10-framework shootout on current `master`: `95%` of bare C on
  plaintext, `1.8–3.0×` the nearest rival on dynamic workloads (see README).
- New `examples/chat/` dogfood app (rooms + JWT + SQLite + rate limits).

## v1.0.0 — First Stable (Non-Blocking WebSockets)

**Breaking (pre-1.0 API):** `app.ws(route)` is now a per-message callback
(`{ msg, ws => … }`); blocking `ws.each_msg` / `ws.recv_into` / `ws.set_timeout`
and C `honk_ws_{recv_exact,send_all,unmask}` are removed. Read `app.param()`
INSIDE the callback (values captured outside dangle across turns).

- Non-blocking WS turns: upgraded conns multiplex on the worker epoll loop
  (core frame pump + Goose-global slots + C lazy message/aux buffers, 1024
  upgrades/worker with 503 past it, fd-reuse revalidation); HTTP flows while
  sockets idle; 1 MiB messages, masking/`Ping`/`Pong`/fragment/`1002`/`1007`/
  `1009` semantics preserved; handshake replays pipelined tail (no more drop).
- `stream()`/`sse()` stay blocking by design (server-push has no event source;
  size `HONK_WORKERS`, see GUIDE).
- SQLite: `order_dir()` allowlist helper + documented no-injection rule.
- Toolchain: pin enforcement + `.build-info` fingerprints + green from-scratch
  CI (incl. GCC 14+ forward-declaration fix).
- Scope: Linux x86_64 + WSL2, Goose pinned `2239b92eb`, HTTP/1.1, semver API.

## v0.10.0 — Dual-Stack IPv6, Bind Control & Unix Domain Sockets

### Networking
- Dual-stack listener: `AF_INET6 ::` with `IPV6_V6ONLY=0` by default
  (graceful `AF_INET` fallback on kernels without v6); v4-mapped peers
  report plain dotted-quad `client_ip` (backward compatible, never
  `::ffff:a.b.c.d`); native v6 via `inet_ntop`.
- Unified 128-bit CIDR matcher (pure Goose, `hi`/`lo` u64): v4 maps to
  `::ffff:0:0/96`, `::` compression + embedded-v4 + `[…]` brackets +
  `/0`..`/128` (shift-safe, no `>> 64` UB); same
  `parse_cidrs("127.0.0.1,10.0.0.0/8,::1,fc00::/7")` signature, now 16 entries.
- Bind control: `honk::listen_at("127.0.0.1" | "::1" | "v6only:::" | …, port)`
  and `$HONK_BIND` env (all runners, default `"::"`).
- Unix sockets: `honk::listen_at("unix:/path.sock", 0)` — pre-fork single
  bind shared by all `HONK_WORKERS` (no `EADDRINUSE`), stale `S_ISSOCK`
  cleanup only (regular files never unlinked), `0660` perms, `client_ip`
  `"unix"`, owner-only `unlink` on shutdown.
- Audit: nothing parses `Host` for ports (path-based routing); XFF walks
  accept bracketed (`[::1]`, `[::1]:8080`) and unbracketed v6 hops.

### CLI
- `./honk dev` watches `.c`/`.h`/`.sql`/`.build` alongside `.goose`
  (rebuild on code, restart-only on data) plus repeatable `--watch <dir>`.

## v0.9.0 — Static & Media Delivery Complete

### Byte ranges & conditional static
- `Range` single-range `206 Partial Content` (`<start>-<end>`, `<start>-`,
  `-<suffix>`) on `GET`/`HEAD` for files (offset `sendfile`) and `embed`;
  `Accept-Ranges: bytes` on `200`/`206`; multi-range/garbage falls back to
  `200`; unsatisfiable (`start >= size`, `start > end`, `-0`, empty file)
  answers `416` with `Content-Range: bytes */<size>`.
- `If-Range`: exact `Last-Modified` match keeps the range, anything else
  (stale date, any `ETag` — file tags are weak) serves full `200`.
- `If-Modified-Since` → `304` via a pure-Goose IMF-fixdate parser (inverse
  of `http_date`, `0` C externs); RFC 9110 §13.2.2 precedence — any present
  `If-None-Match` disables IMS evaluation; malformed dates serve `200`.
- New `app.static_file(route, root, rel, cache_ctl = "")` single-file helper
  (non-breaking companion to `static_dir` / `static_dir_cached`).

### Precompressed sidecars (zero C libraries)
- `Accept-Encoding` negotiation (`br` preferred over `gzip`, `;q=0` honored):
  serves `<path>.br` / `<path>.gz` sidecars with original MIME,
  `Content-Encoding`, always-on `Vary: Accept-Encoding`, and `-br`/`-gz`
  `ETag` suffixes. Only probed for compressible types (text/JSON/XML/SVG/
  WASM — never media/fonts) and never combined with `Range`.

## v0.8.0 — Hardening (trusted proxies, no silent truncation, production basics)

**Breaking:** `app.rate_limit()` now keys by the socket peer IP (unspoofable).
Behind a reverse proxy, key explicitly instead:
`app.rate_limit_key(app.real_ip_trusted(nets), max, win)` with
`honk::parse_cidrs("127.0.0.1,10.0.0.0/8")` parsed once in `main`.

### Security & correctness
- Trusted proxies: `parse_cidrs` / `parse_ipv4` / `real_ip_trusted` with a
  right-to-left `X-Forwarded-For` walk (leftmost spoof ignored), fail-closed
  to the socket peer on malformed hops.
- C-side `honk_file_open` re-rejects `..` segments, backslashes, and NULs
  across FFI (defense in depth behind the Goose-side validator).
- WebSockets: strict UTF-8 validation on text messages (RFC 6455 §8.1),
  protocol error closes with `1007`.
- `app.cors_cfg()`: origin allowlist with exact-match echo, `Vary: Origin`
  always in allowlist mode, `credentials` refused with `"*"`, `Max-Age`.
- `app.request_id()` (validated echo or `w<worker>-<ns>`) + `app.access_log()`
  (single-write NDJSON, JSON-escaped, fork-safe).

### Raised ceilings (no more silent truncation where it hurts)
- Response headers `8 → 16`, route `:params` `4 → 8` (~400 B request stack).
- `status_text()`: added `206/408/409/412/413/414/415/416/431/500–504`.
- Static: `Last-Modified` (pure-Goose IMF-fixdate) + media MIME rows
  (`mp4/webm/mp3/wav/ogg/avif/gif/pdf/xml/woff`).
- Validators: `body_f64` / `require_float` / `require_float_range`.
- OpenAPI: `spec.op_raw()` (raw fragment before `responses`) + self-hostable
  `app.docs(..., cdn_url)`; in-memory `Tester` captures static `resp_hdrs`.

## v0.1.0 — First public release

Honk is a zero-copy HTTP/1.1 backend framework in Goose (AOT-compiled to C):
`89%` of hand-written C speed, `~2 MB` flat RSS, `~150 KiB` zero-dependency
binaries, and zero per-request heap allocations — with an API as small as
Hono or Flask.

### Transport & stack discipline (`src/shim/`, `src/honk_net/`)
- Linux `epoll` + `SO_REUSEPORT` multi-worker server with CPU pinning.
- `recv()` straight into the Goose data-stack top (`gs_rref`); only split
  tails spill to lazy per-connection C buffers; `EAGAIN` send tails queue
  with `EPOLLOUT` resume. Caps: 4096 conns/worker, 8 KiB headers (`431`),
  1 MiB bodies (`413`), 1 MiB pending-tx, idle + slowloris timeouts.
- All `gs_rref` access isolated in `honk_rref.h` with compile-time layout
  asserts; 900,000-turn stack-discipline test; ASan+UBSan+LSan clean.

### Router, middleware & JSON (`src/honk_ctx/`, `src/honk_json/`, `src/honk_router/`)
- Zero-copy `Ctx`: method/path/query/headers/params/body views, case-insensitive
  header lookup, typed `param_int`/`query_int_or`, percent-decoding, bearer
  tokens, cookies, redirects, CORS, wildcard routes with `..` rejection.
- Dispatch-as-code router (static, `:param`, multi-param, `404`/`405`) and
  composable middleware (before/after/auth-guard) — all inlined, zero-cost.
- Stdlib JSON only: zero-DOM `Reader` typed binding, DOM `parse`, in-place
  `format_*` emit, strict `400`s. `HEAD` + HTTP pipelining throughout.

### One-call API (`src/honk_serve/`) & `./honk` CLI
- `honk::listen/serve/request` blocks: a complete app in ~15 lines; framework
  owns the epoll loop, per-request scopes, default `404`, emit, and shutdown.
- `./honk setup|doctor|new|dev|build|test`: pinned-toolchain bootstrap,
  scaffolding, auto-reload dev, release/ASan builds, full test runner.

### Static files & SQLite (`src/honk_static/`, `src/honk_sqlite/`)
- Kernel-`sendfile()` static serving: MIME table, `HEAD`, `index.html`
  fallback, SPA mode, traversal/symlink/FIFO hardening, non-blocking
  `EAGAIN`+`EPOLLOUT` resume with zero fd leaks.
- Opt-in SQLite: per-worker WAL connections, prepared statements (injection-
  proof by construction), single-copy column readers into request scope.
  Non-SQLite binaries link no `libsqlite3` and keep their footprint.

### Benchmarks, examples & docs
- 10-framework shootout (`bench/run_bench_compete.py`): Honk wins every
  dynamic workload at 2.1–3.4× the nearest rival (single-core, WSL2
  indicative) — see `docs/history/phase3-report.md`.
- `examples/quickstart/` and `examples/fullstack_todo/` (single-binary Todo
  app: sendfile frontend + SQLite API); `Dockerfile`, GitHub Actions CI,
  `MIT` license; `QUICKSTART`/`GUIDE`/`API` docs + `CONTRIBUTING` invariants.
