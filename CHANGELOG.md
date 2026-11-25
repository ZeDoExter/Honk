# Changelog

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
