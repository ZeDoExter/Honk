# Honk API Reference

All application-facing modules and functions. Apps normally write one import:

```goose
import honk from "<honk>/src";          // barrel: net + ctx + serve + app DSL + static
import honk.honk_sqlite.honk_sqlite;    // opt-in: SQLite (-lsqlite3)
```

Core types and server runners live in `namespace honk` (`honk::Ctx`,
`honk::Config`, `honk::listen`, `honk::JWriter`, …); `Ctx` and `JWriter`
helpers are called with method syntax (`app.get(...)`, `app.ok(...)`,
`j.str(...)`) via UFCS. Route and response helpers are `inline fn`s: unused
helpers compile away and hot-path routes monomorphize directly into the worker
loop with zero closure allocations.

Conventions: `const u8[:]` = zero-copy read-only view (never heap-allocated);
`bool` second return = `ok` (always check it); `app.res` = response builder,
`app.tmp` = decode/scratch space, `app.dom`/`app.dstr` = JSON DOM/scratch
workspace (all reset automatically after every request).

## Server runner (`honk::`)

| Signature | Notes |
|---|---|
| `honk::listen(port: i32) { app => … };` | Single-worker server on `main`: `listen_or_abort` + `serve` + `request_app` (auto `404`/`405` + clean shutdown on `honk_request_stop()`) |
| `honk::listen_cfg(cfg: Config&) { app => … };` | `listen` with full `honk::Config` (timeouts, worker id, CPU pin) |
| `honk::request_app(fd, date) { app => … };` | `inline` turn wrapper with App DSL `405`/`404` tracking; pair with `honk::serve()` in multi-worker `thread_fn`s |
| `honk::app_run(ctx) { app => … };` | Runs block against an existing `Ctx&`, then stages `405` if `path_matched && !handled` |
| `struct honk::Config { port, idle_ms = 30000, header_ms = 10000, worker_id = 0, cpu_id = -1 }` | `-1` = no CPU pinning |
| `honk::listen_or_abort(port: i32)` | Low-level init (default timeouts, no pin); aborts on failure |
| `honk::listen_cfg_or_abort(cfg: Config&)` | Low-level init with full `Config`; aborts on failure |
| `honk::serve() { fd, date => … };` | `inline` epoll loop; calls `honk_worker_shutdown()` when `honk_should_stop() != 0` |
| `honk::request(fd, date) { ctx => … };` | Low-level turn without `405` route tracking (unstaged requests default to `404`) |
| `honk_request_stop()` / `honk_should_stop() -> i32` | Request / query clean loop exit for the current worker |

## Declarative routes (`honk::Ctx&` as `app`, first-match-wins)

Every route records `app.path_matched = true` when its path pattern matches, and
sets `app.handled = true` after running when the HTTP method also matches (`GET`
routes also accept `HEAD`).

| Signature | Notes |
|---|---|
| `app.get(path, body)` / `app.get_text(path, body)` | Static `200 text/plain` literal |
| `app.get_json_raw(path, body)` | Static `200 application/json` pre-serialized literal |
| `app.get(path) { … };` | `GET` / `HEAD` exact-path block |
| `app.post(path) { … };` / `.put` / `.patch` / `.delete` | Exact-path method blocks |
| `app.get_param("/p/:name") { val => … };` | Single non-empty `/`-free segment (also populates `app.params[0]`) |
| `app.get_int("/p/:id") { id => … };` | Strict `i64` param; auto-stages `400 {"error":"path parameter must be an integer"}` on bad input |
| `app.patch_int("/p/:id") { id => … };` | `PATCH` variant of `get_int` |
| `app.delete_int("/p/:id") { id => … };` | `DELETE` variant of `get_int` |
| `app.get2("/a/:x/b/:y") { x, y => … };` | Two non-empty `/`-free segments (also populates `app.params[0..2]`) |
| `app.get_wild("/p/*") { rest => … };` | Non-empty remainder after prefix (may contain `/`; pair with `honk::has_dotdot(rest)` when mapping to paths) |
| `app.patch_wild("/p/") { rest => … };` | `PATCH` prefix-remainder match (e.g. `/api/todos/:id/toggle`) |
| `app.static_dir(prefix, root)` | Mount `root` directory under `prefix` (`"/"` or `"/assets/"`) via `sendfile` + `index.html` |

## Concise responses, streaming `JWriter`, & JSON body helpers

| Signature | Notes |
|---|---|
| `app.ok(body)` | `200 text/plain` |
| `app.ok_json()` | `200 application/json` (`{"ok":true}`) |
| `app.json() { j => … };` | Streams `{…}` directly into `app.res` and stages `200 application/json` |
| `app.created_json() { j => … };` | `201 Created` variant of `app.json()` |
| `j.str(key, val)` | Escaped JSON key + string value (auto comma) |
| `j.int(key, val: i64)` | Escaped JSON key + integer value |
| `j.jbool(key, val: bool)` | Escaped JSON key + `true`/`false` |
| `j.jnull(key)` | Escaped JSON key + `null` |
| `j.raw(key, fragment)` | Escaped JSON key + pre-serialized JSON value fragment |
| `app.body_str(key) -> val, bool` | Reads string field from memoized request JSON DOM |
| `app.body_int(key) -> i64, bool` | Reads integer field from request JSON DOM |
| `app.body_bool(key) -> bool, bool` | Reads boolean field from request JSON DOM |
| `app.require_str(key) { val => … };` | Runs block with non-empty string field, else stages `400 {"error":"invalid or missing field"}` |

## Request views & low-level response staging (`honk::Ctx&`)

| Signature | Notes |
|---|---|
| `ctx.method`, `.path`, `.query_str`, `.body`, `.hdrs`, `.keep_alive`, `.head_only`, `.fd`, `.handled`, `.path_matched` | Request views into `rx_buf` + routing flags |
| `ctx.header(name) -> val, bool` | Case-insensitive, OWS-trimmed scan |
| `ctx.query(key) -> val, bool` | Raw `k=v&` scan, first wins, no decoding |
| `ctx.query_str_or(key, default) -> val` | Default when absent |
| `ctx.query_int_or(key, default: i64) -> i64` | Default when absent/invalid/overflowing |
| `ctx.query_decoded(key) -> val, bool` | `%XX` + `+`→space via `ctx.tmp`; zero-copy when clean |
| `ctx.param_str(i) -> val` | `params[i]` or `""` |
| `ctx.param_int(i) -> i64, bool` | Strict `i64` parse of `params[i]` |
| `ctx.param_decoded(i) -> val, bool` | `%XX` via `ctx.tmp` (`+` stays literal) |
| `ctx.rest(prefix) -> rest, bool` | Non-empty remainder after `prefix` |
| `honk::has_dotdot(s) -> bool` | `true` on any `..` path segment |
| `honk::match_1param(path, prefix) -> seg, bool` | Single non-empty `/`-free segment |
| `honk::parse_i64_strict(s) -> i64, bool` | Strict signed 64-bit integer parser |
| `ctx.bearer_token() -> token, bool` | `Authorization: Bearer …` (scheme case-insensitive) |
| `ctx.cookie(name) -> val, bool` | `Cookie` header lookup |
| `ctx.text(status, s)` / `.html(status, s)` / `.bytes(status, s)` | Stage `text/plain`, `text/html`, `application/octet-stream` |
| `ctx.json_raw(status, s)` | Stage pre-serialized `application/json` |
| `ctx.json_error(code, msg)` | Stage `{"error":"…"}` (escaped into `ctx.res`) |
| `ctx.no_content()` | Empty `204` |
| `ctx.redirect(location, code = 302)` | `Location` header + empty body |
| `ctx.set_header(name, val)` | Custom response header (max 8) |
| `ctx.set_cookie(name, val, opts = "")` | Builds `name=val[; opts]` in `ctx.tmp` + `Set-Cookie` |
| `ctx.cors_allow_all()` / `.cors_with_origin(origin)` / `.cors_preflight()` | CORS response headers / `204` preflight |
| `honk::status_text(code) -> phrase` | HTTP reason phrase table |
| `ctx.emit(out, date)` | Central HTTP/1.1 framing emitter |

## Stdlib JSON (`json::`)

| Signature | Notes |
|---|---|
| `json::reader(body) -> Reader` | Streaming pull parser (zero DOM allocation) |
| `json::each_member(r) { key => … };` / `json::each_element(r) { … };` | Object / array iteration blocks |
| `json::read_string(r, scratch)` / `read_int(r)` / `read_number(r)` / `read_bool(r)` / `skip(r)` | Typed streaming reads |
| `json::finish(r) -> bool` | `false` on syntax/type error or trailing bytes |
| `json::format_key/format_string/format_int/format_number/format_bool(out, …)` | In-place escaping/formatting into `u8[>..]&` |
| `json::parse(text, doc, decoded) -> root?, err` | Scoped DOM parser; inspect with `member`, `as_string`, `as_i64`, `as_bool`, `each` |

## Static files (`honk_static`, re-exported by `honk`)

| Signature | Notes |
|---|---|
| `app.static_dir(prefix, root)` | App DSL mount for `GET`/`HEAD` (with `index.html` resolution and `405` tracking) |
| `try_serve_file(ctx, root, with_index) -> bool` | Low-level `GET`/`HEAD` handler (`true` = `200`/`HEAD`/`405` staged; `false` = miss/rejected) |
| `serve_rel(ctx, root, rel, with_index) -> bool` | Serve an explicit relative path (e.g. SPA `"index.html"` fallback) |
| `mime_for_rel(rel) -> ctype` | Extension MIME lookup (14 web types, else `application/octet-stream`) |

## SQLite (`import honk.honk_sqlite.honk_sqlite;`, opt-in `-lsqlite3`)

| Signature | Notes |
|---|---|
| `app.sql_json(db, sql)` | `SELECT` → `200` JSON array (`[]` when empty; `INT`/`FLOAT`/`TEXT`/`NULL` columns; `500` on error, never partial) |
| `app.sql_json_one(db, sql, id: i64)` | `SELECT … WHERE id = ?1` → `200` JSON object, `404` when empty, `500` on error |
| `app.sql_json_one_text(db, sql, val)` | Single `TEXT`-param variant of `sql_json_one` (`TRANSIENT` bind) |
| `insert_text(db, sql, text) -> id: i64, bool` | Parameterized 1-text `INSERT` returning `last_insert_rowid()` |
| `run_int(db, sql, id: i64) -> changes: i64, bool` | Parameterized 1-int `UPDATE`/`DELETE` returning affected row count |
| `struct Db { h }`, `struct Stmt { h }` | Opaque handles; one `Db` per worker thread |
| `db_open(path) -> Db, bool` | `READWRITE \| CREATE \| NOMUTEX` |
| `db_enable_wal(db) -> bool` | `busy_timeout=5000`, `WAL`, `synchronous=NORMAL`, `foreign_keys=ON` |
| `db_exec(db, sql) -> bool` | DDL / multi-statement exec |
| `db_close(db) -> bool` / `db_shutdown() -> bool` | Close worker handle / release global SQLite state after workers join |
| `db_prepare(db, sql) -> Stmt, bool` / `stmt_finalize(st) -> bool` | Reusable prepared statements |
| `stmt_step(st) -> i32` / `stmt_reset(st) -> bool` | Step (`ROW = 100`, `DONE = 101`) / reset + clear bindings |
| `bind_int/bind_float/bind_text/bind_text_static/bind_null(st, idx, …) -> bool` | 1-based parameter binding |
| `col_int/col_float/col_is_null(st, idx)` / `col_text(st, idx, out) -> slice, bool` / `col_name(st, idx, out) -> slice, bool` | 0-based column readers |
| `db_last_id(db) -> i64` / `db_changes(db) -> i64` | Last rowid / changed rows |

## Low-level transport (`honk_net`, rarely needed in apps)

`honk_worker_init/shutdown`, `honk_wait`, `honk_conn_read`, `honk_parse_req`,
`honk_send`, `honk_sendfile_data`, `honk_conn_finish`, `honk_close`,
`honk_pin_thread_cpu`, `honk_set_timeouts`, telemetry (`honk_worker_id`,
`honk_active_conns`, `honk_accepted_total`, `honk_rejected_conns`,
`honk_timed_out_conns`, `honk_tx_queued_count`), `honk_shrink_sndbuf`,
`honk_debug_stack_top/base`, `RawReq`, `write_response`, `write_error_response`.
