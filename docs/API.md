# Honk API Reference

All application-facing modules and functions. Honk ships `honk.goose` +
`honk.build` at the repository root (with opt-in SQLite in `sqlite/` and
opt-in unit testing in `src/honk_test/`):

```goose
import honk from "ZeDoExter/Honk@v1.0.0";   // or relative "../Honk"
import honk.src.honk_auth.honk_auth;        // opt-in: JWT (HS256) + signed cookies
import honk.src.honk_ws.honk_ws;            // opt-in: RFC 6455 WebSockets
import honk.src.honk_openapi.honk_openapi;  // opt-in: OpenAPI 3.1.0 + Docs UI
import honk_sqlite from "../Honk/sqlite";   // opt-in: SQLite (-lsqlite3)
import honk.src.honk_test.honk_test;        // opt-in: in-memory unit tester
```

Core types and server runners live in `namespace honk`; unused `inline fn`
helpers compile away completely so minimal binaries stay `~150 KiB`.

## Server runner & lifecycle (`honk::`)

| Signature | Notes |
|---|---|
| `honk::listen(port: i32) { app => … };` | 1 worker by default, or `$HONK_WORKERS` (`1..64` / `"auto"`) `SO_REUSEPORT` processes; auto `404`/`405`; drains up to `2s` on `SIGINT`/`SIGTERM` |
| `honk::listen_at(bind, port) { app => … };` | Explicit bind: `"0.0.0.0"`, `"127.0.0.1"`, `"::"`, `"::1"`, v6 literal, `"v6only:::"`, or `"unix:/path.sock"` (`$HONK_BIND` or `"::"` when using `listen`) |
| `honk::listen_workers(port: i32, n: i32) { app => … };` | Explicit multi-worker `listen` (`0` = `sched_getaffinity` CPU count, `1..64`) |
| `honk::workers(n: i32) -> i32` / `honk::workers_env() -> i32` | Pre-`db_open()` worker fork (`0` = auto, `1..64`, or `$HONK_WORKERS`) |
| `honk::arg_port(default_port: i32) -> i32` | Reads `argv[1]` when in `1..65535`, else `default_port` |
| `app.group(prefix) { … };` | Nestable zero-alloc route prefix group (`"/api/v1"`); skips block in one branch when prefix misses |
| `app.cors()` / `app.cors(origin)` | One-line CORS headers + automatic `204` `OPTIONS` preflight (`handled = true`) |
| `app.cors_cfg(allow, methods?, headers?, max_age?, creds?)` | Origin allowlist (or `"*"`) with exact-match echo, always-on `Vary: Origin`, `credentials` refused with `"*"`, `Max-Age`, auto-`204` `OPTIONS` |
| `app.bearer() { tok => … };` | Scoped Bearer auth guard; runs block on valid token, else stages `401` (`handled = true`) |
| `app.rate_limit(max_reqs, window_sec)` / `app.rate_limit_key(key, max, win)` | Socket-IP-keyed fixed-window limiter (unspoofable); sets `X-RateLimit-Remaining` or `429` + `Retry-After` (behind a proxy, key by `real_ip_trusted`) |
| `honk::parse_cidrs("127.0.0.1,10.0.0.0/8,::1,fc00::/7")` / `app.real_ip_trusted(nets)` | Trusted-proxy allowlist, max 16 (parsed once) + spoof-resistant client IP via right-to-left `X-Forwarded-For` walk over unified 128-bit v4/v6 addrs, fail-closed to socket peer |
| `app.client_ip()` / `app.real_ip()` | Socket peer (`"127.0.0.1"` / `"::1"` / `"unix"` for Unix sockets) / legacy proxy-aware IP (no allowlist) |
| `app.json_errors()` | Emits `application/json` `{"error":...}` for default `404` / `405` / `401` / `429` responses |
| `app.server_timing()` | Attaches `Server-Timing: honk;dur=<ms>.<us>` measured via `CLOCK_MONOTONIC` |
| `app.request_id()` / `app.after() { app.access_log(); };` | Validated `X-Request-Id` echo or generated `w<worker>-<ns>` / single-write NDJSON access log (`ts/m/p/s/ip/rid`, JSON-escaped) |
| `app.after() { … };` | Resolves pending `404`/`405` first so `app.status` reflects the final status code |
| `honk::listen_cfg(cfg)` / `honk::request_app(fd, date)` / `honk::app_run(ctx)` | Configurable / `thread_fn` entry points |
| `honk::listen_or_abort` / `listen_cfg_or_abort` / `serve` / `request` / `honk_request_stop` / `honk_should_stop` | Low-level runner primitives |

## Unified pattern routes (`honk::Ctx&` as `app`, first-match-wins)

| Signature | Notes |
|---|---|
| `app.get(route, body)` / `app.get_text(route, body)` | Static `200 text/plain` response |
| `app.get_json_raw(route, body)` | Static `200 application/json` pre-serialized literal |
| `app.get(route) { … };` | `GET` / `HEAD` unified pattern block (`static`, `:param` + suffixes, `/*`) |
| `app.post` / `.put` / `.patch` / `.delete` / `.options` / `.all(route) { … };` | Unified pattern blocks for each HTTP method (`all` matches any method) |
| `app.param(name) -> val` / `app.param(i: i64) -> val` | Zero-copy `:param` lookup by name (`app.param("id")`) or index (`app.param(0)`), up to 8 params per route |
| `app.param_dec(name) -> val, bool` | Percent-decoded named `:param` (`+` stays literal) |
| `app.tail` | Zero-copy wildcard remainder matched by trailing `/*` |
| `app.get_int` / `.post_int` / `.put_int` / `.patch_int` / `.delete_int(route) { id => … };` | Strict `i64` first `:param` (suffixes like `/todos/:id/toggle` allowed; auto-`400` JSON on bad int) |
| `app.static_dir(prefix, root)` | Mount `root` directory via `sendfile` + `index.html` |
| `app.get_param` / `app.get2` / `app.get_wild` / `app.patch_wild` | Param-passing compatibility aliases |

## Streaming JSON (`JWriter` & `JArray`) & body validators

| Signature | Notes |
|---|---|
| `app.ok(body)` / `app.ok_json()` | `200 text/plain` / `200 {"ok":true}` |
| `app.json() { j => … };` / `app.created_json() { j => … };` | `200` / `201` streaming JSON object `{…}` |
| `app.json_list() { a => … };` | `200` streaming JSON array `[…]` |
| `j.set(key, val)` | Overloaded for `const u8[:]`, `i64`, `f64`, and `bool` |
| `j.obj(key) { child => … };` / `j.arr(key) { arr => … };` | Nested JSON object / array field on `JWriter` |
| `j.str` / `.int` / `.num` / `.jbool` / `.jnull(key)` / `.raw(key, frag)` | Explicit-type / `null` / raw fragment writers on `JWriter` |
| `a.add(val)` | Overloaded for `const u8[:]`, `i64`, `f64`, and `bool` on `JArray` |
| `a.obj() { j => … };` / `a.arr() { inner => … };` / `a.jnull()` / `a.raw(frag)` | Nested object / array / `null` / raw element on `JArray` |
| `app.body_str(key)` / `body_int(key)` / `body_bool(key)` / `body_f64(key)` | Memoized JSON DOM field readers (`val, bool`) |
| `app.require_str(key) { val => … };` | Non-empty string or `400 {"error":"invalid or missing field: <key>"}` |
| `app.require_str_len(key, min, max) { val => … };` | Bounded-length string or `400 {"error":"invalid length for field: <key>"}` |
| `app.require_int(key) { val => … };` | Integer field or `400 {"error":"invalid or missing field: <key>"}` |
| `app.require_int_range(key, min, max) { val => … };` | Bounded integer or `400 {"error":"out of range: <key>"}` |
| `app.require_bool(key) { val => … };` | Boolean field or `400 {"error":"invalid or missing field: <key>"}` |
| `app.require_float(key) { val => … };` | Float field or `400 {"error":"invalid or missing field: <key>"}` |
| `app.require_float_range(key, min, max) { val => … };` | Bounded float or `400 {"error":"out of range: <key>"}` |
| `app.form(key)` / `form_or(key, def)` / `form_int(key)` | Decoded `x-www-form-urlencoded` (or `multipart/form-data` text) field |
| `app.require_form(key) { val => … };` | Non-empty form field or `400 {"error":"invalid or missing field: <key>"}` |
| `app.multipart_file(key) -> Part, bool` / `multipart_part(key)` | Zero-copy RFC 7578 `Part { name, filename, ctype, data, has_file }` (`filename` stripped to basename) |
| `app.each_part() { part => … } -> bool` | Iterate all parts in a `multipart/form-data` request; `false` if malformed |
| `app.stream(ctype = "text/plain") { s => s.write(chunk); };` | HTTP/1.1 `Transfer-Encoding: chunked` streaming response (`s.closed` tracks peer disconnect) |
| `app.sse() { ev => … };` | `text/event-stream` (`ev.send`, `ev.event`, `ev.id_event`, `ev.comment`, `ev.retry`) |

## In-memory unit tester (`import honk.src.honk_test.honk_test;`)

| Signature | Notes |
|---|---|
| `honk::tester() -> Tester` | Value-owned test harness (zero sockets, reusable across thousands of requests) |
| `t.get(target) { app => … };` / `t.get_headers(target, hdrs) { app => … };` / `t.delete(target) { app => … };` | Synthetic `GET` / `DELETE` |
| `t.post_json` / `put_json` / `patch_json(target, json_body) { app => … };` / `t.post_form(target, form_body) { app => … };` | Synthetic JSON / URL-encoded form requests |
| `t.req(method, target, hdrs, body) { app => … };` | Arbitrary synthetic HTTP/1.1 request |
| `t.status`, `t.body() -> slice`, `t.ctype() -> slice`, `t.header(name) -> val, bool` | Inspect emitted status, `Content-Type`, body, and response headers |

## Request views & low-level response staging (`honk::Ctx&`)

`ctx.header(name)`, `ctx.query(key)`, `ctx.query_str_or(key, def)`,
`ctx.query_int_or(key, def)`, `ctx.query_decoded(key)`, `ctx.param_str(i)`,
`ctx.param_int(i)`, `ctx.param_decoded(i)`, `ctx.rest(prefix)`,
`honk::has_dotdot(s)`, `honk::match_1param(path, prefix)`,
`honk::parse_i64_strict(s)`, `ctx.bearer_token()`, `ctx.cookie(name)`,
`ctx.text/html/bytes/json_raw(status, s)`, `ctx.json_error(code, msg)`,
`ctx.no_content()`, `ctx.redirect(loc, code = 302)`, `ctx.set_header(name, val)`,
`ctx.set_cookie(name, val, opts = "")`, `ctx.cors_allow_all/cors_with_origin/cors_preflight`,
`honk::status_text(code)`, `ctx.emit(out, date)`.

## Auth: JWT (`HS256`) & Signed Cookies (`import honk.src.honk_auth.honk_auth;`)

| Signature | Notes |
|---|---|
| `app.jwt_issue(secret, sub, ttl_sec) -> token` | Emits signed `{"sub":...,"iat":...,"exp":...}` HS256 JWT into `app.tmp` |
| `app.jwt(secret) { claims => … };` | Verifies `Bearer <jwt>` (constant-time MAC + `alg=="HS256"` + `exp`/`nbf`), sets `app.user`, or stages `401` |
| `app.jwt_claim_str(claims, key)` / `app.jwt_claim_int(claims, key)` | Extract typed claim from verified payload JSON |
| `honk::jwt_sign(payload_json, secret, out)` / `honk::jwt_verify(tok, secret, scratch)` | Low-level HS256 sign & verify |
| `app.set_signed_cookie(name, val, secret, opts = ...)` | HMAC-SHA256 cookie (`name=val.<sig>`, binds `name` against swap attacks) |
| `app.signed_cookie(name, secret) -> val, bool` | Constant-time verified cookie lookup |
| `app.delete_cookie(name, path = "/")` | Expires cookie (`Max-Age=0; HttpOnly`, in `honk_ctx`) |
| `honk::sha256(msg)` / `hmac_sha256(key, msg)` / `b64url_encode` / `b64url_decode` / `ct_eq` | Pure-Goose RFC 6234 / 2104 / 4648 primitives |

## Static files (`honk_static`) & SQLite (`sqlite/honk_sqlite`)

- **Static**: `app.static_dir(prefix, root)`, `app.static_dir_cached(prefix, root, cache_ctl)` (kernel `sendfile` + automatic `ETag` / `304 Not Modified` + `Last-Modified` + media MIME rows), `app.static_file(route, root, rel, cache_ctl = "")` (single file), `app.embed(route, data, mime = "", cache_ctl = "")` (serves compile-time `embed_file(...)` bytes with FNV-1a `ETag` / `304`), single-range `Range` → `206` / `416` + `If-Range` + `If-Modified-Since` on all three, precompressed `.br`/`.gz` sidecars (`Accept-Encoding` + `Vary`, `-br`/`-gz` ETags), `try_serve_file`, `serve_rel`, `mime_for_rel`, `http_date`, `parse_imf_date`, `parse_range`.
- **SQLite**: `db_connect(path, schema = "")`, `app.sql_json(db, sql)` (`BOOLEAN`/`BOOL` columns auto-emit `true`/`false`), `app.sql_json_one(db, sql, id)`, `app.sql_json_one_text(db, sql, val)`, `order_dir(s)` (allowlisted `"DESC"`/`"ASC"` for dynamic `ORDER BY`), `insert_text(db, sql, text)`, `run_int(db, sql, id)`, `db_open/db_enable_wal/db_exec/db_close/db_shutdown`, `db_prepare/stmt_finalize/stmt_step/stmt_reset`, `bind_int/float/text/text_static/null`, `col_int/float/is_null/text/name`, `db_last_id/db_changes`.

## WebSockets (`import honk.src.honk_ws.honk_ws;`) & OpenAPI (`import honk.src.honk_openapi.honk_openapi;`)

- **WebSockets (`RFC 6455`, non-blocking)**: `app.ws(route) { msg, ws => … };` (one callback per message; `101` + `426`/`400`/`503` handshake), `ws.send(text)`, `ws.send_bytes(data)`, `ws.send_json() { j => … };`, `ws.ping(payload = "")`, `ws.close(code = 1000)`, `ws.opcode`, `honk::sha1(msg)`, `honk::b64_encode(src, out)`, `honk::ws_accept_key(key, out)`.
- **OpenAPI `3.1.0` & Docs UI**: `app.openapi(route, title, version) { spec => … };` (`spec.desc`, `spec.server`, `spec.bearer_auth`, `spec.op`, `spec.op_int`, `spec.op_body`, `spec.op_auth`, `spec.op_raw` — auto `:param` → `{param}` conversion and same-path operation merging), `app.docs(route, spec_url, title = "API Reference", cdn_url = "…")` (self-hostable Scalar CDN URL).
