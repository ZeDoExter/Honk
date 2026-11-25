# Honk API Reference

All application-facing modules and functions. Honk ships `honk.goose` +
`honk.build` at the repository root (and opt-in SQLite in `sqlite/`), so user
applications never need a `.build` file of their own:

```goose
import honk from "ZeDoExter/Honk@v0.3.0";   // or relative "../Honk"
import honk_sqlite from "../Honk/sqlite";   // opt-in: SQLite (-lsqlite3)
```

Core types and server runners live in `namespace honk` (`honk::Ctx`,
`honk::Config`, `honk::listen`, `honk::JWriter`, …); `Ctx` and `JWriter`
helpers are called with method syntax (`app.get(...)`, `app.ok(...)`,
`j.set(...)`) via UFCS. Route and response helpers are `inline fn`s: unused
helpers compile away and hot-path routes monomorphize directly into the worker
loop with zero closure allocations.

Conventions: `const u8[:]` = zero-copy read-only view (never heap-allocated);
`bool` second return = `ok` (always check it); `app.res` = response builder,
`app.tmp` = decode/scratch space, `app.dom`/`app.dstr` = JSON DOM/scratch
workspace (all reset automatically after every request).

## Server runner (`honk::`)

| Signature | Notes |
|---|---|
| `honk::listen(port: i32) { app => … };` | Server on `main`: 1 worker by default, or `$HONK_WORKERS` (`1..64` / `"auto"`) `SO_REUSEPORT` processes; auto `404`/`405`; drains outbound bytes (up to `2s`) and joins workers on `SIGINT`/`SIGTERM`/`honk_request_stop()` |
| `honk::listen_workers(port: i32, n: i32) { app => … };` | Explicit multi-worker `listen` (`n = 0` for `sched_getaffinity` CPU count, `1..64`) |
| `honk::workers(n: i32) -> i32` / `honk::workers_env() -> i32` | Pre-`db_open()` worker fork (`0` = auto, `1..64`, or `$HONK_WORKERS`); exits with an error if a SQLite `Db` handle is already open |
| `honk::arg_port(default_port: i32) -> i32` | Reads `argv[1]` when in `1..65535`, else returns `default_port` |
| `honk::listen_cfg(cfg: Config&) { app => … };` | `listen` with full `honk::Config` (timeouts, worker id, CPU pin) |
| `honk::request_app(fd, date) { app => … };` | `inline` turn wrapper with `405`/`404` tracking; pair with `honk::serve()` in multi-worker `thread_fn`s |
| `honk::app_run(ctx) { app => … };` | Runs block against an existing `Ctx&`, then stages `405` if `path_matched && !handled` |
| `struct honk::Config { port, idle_ms = 30000, header_ms = 10000, worker_id = 0, cpu_id = -1 }` | `-1` = no CPU pinning |
| `honk::listen_or_abort(port: i32)` | Low-level init (default timeouts, no pin); aborts on failure |
| `honk::listen_cfg_or_abort(cfg: Config&)` | Low-level init with full `Config`; aborts on failure |
| `honk::serve() { fd, date => … };` | `inline` epoll loop; wakes on `SIGINT`/`SIGTERM`/`honk_request_stop()` and runs `honk_worker_shutdown()` |
| `honk::request(fd, date) { ctx => … };` | Low-level turn without `405` route tracking (unstaged requests default to `404`) |
| `honk_request_stop()` / `honk_should_stop() -> i32` | Programmatic stop (propagates across forked workers) / query stop flag |

## Unified pattern routes (`honk::Ctx&` as `app`, first-match-wins)

Every route short-circuits immediately once `app.handled` is `true`, records
`app.path_matched = true` when its pattern matches `app.path`, and sets
`app.handled = true` after running when the HTTP method also matches (`GET`
routes also accept `HEAD`). Patterns support static paths, up to 4 `:param`
segments (including literal suffixes like `/todos/:id/toggle`), and trailing
`/*` wildcards (`app.tail`).

| Signature | Notes |
|---|---|
| `app.get(route, body)` / `app.get_text(route, body)` | Static `200 text/plain` response |
| `app.get_json_raw(route, body)` | Static `200 application/json` pre-serialized literal |
| `app.get(route) { … };` | `GET` / `HEAD` unified pattern block (`static`, `:param`, `/*`) |
| `app.post(route) { … };` / `.put` / `.patch` / `.delete` | Unified pattern blocks for `POST` / `PUT` / `PATCH` / `DELETE` |
| `app.param(name: const u8[:]) -> val` / `app.param(i: i64) -> val` | Zero-copy `:param` lookup by name (`app.param("id")`) or index (`app.param(0)`) |
| `app.tail` | Zero-copy wildcard remainder matched by trailing `/*` |
| `app.get_int(route) { id => … };` | Strict `i64` first `:param` (suffixes allowed); auto-stages `400 {"error":"path parameter must be an integer"}` on bad input |
| `app.post_int` / `.put_int` / `.patch_int` / `.delete_int(route) { id => … };` | `POST` / `PUT` / `PATCH` / `DELETE` variants of `get_int` (e.g. `patch_int("/todos/:id/toggle")`) |
| `app.static_dir(prefix, root)` | Mount `root` directory under `prefix` (`"/"` or `"/assets/"`) via `sendfile` + `index.html` |
| `app.get_param` / `app.get2` / `app.get_wild` / `app.patch_wild` | Param-passing compatibility aliases |

## Concise responses, streaming `JWriter`, & JSON body helpers

| Signature | Notes |
|---|---|
| `app.ok(body)` | `200 text/plain` |
| `app.ok_json()` | `200 application/json` (`{"ok":true}`) |
| `app.json() { j => … };` | Streams `{…}` directly into `app.res` and stages `200 application/json` |
| `app.created_json() { j => … };` | `201 Created` variant of `app.json()` |
| `j.set(key, val)` | Overloaded for `const u8[:]` (escaped string), `i64`, `f64`, and `bool` (auto comma) |
| `j.str(key, val)` / `.int(key, v)` / `.num(key, v)` / `.jbool(key, v)` | Explicit-type equivalents of `j.set` |
| `j.jnull(key)` | Escaped JSON key + `null` |
| `j.raw(key, fragment)` | Escaped JSON key + pre-serialized JSON value fragment |
| `app.body_str(key) -> val, bool` | Reads string field from memoized request JSON DOM |
| `app.body_int(key) -> i64, bool` | Reads integer field from request JSON DOM |
| `app.body_bool(key) -> bool, bool` | Reads boolean field from request JSON DOM |
| `app.require_str(key) { val => … };` | Runs block with non-empty string field, else stages `400 {"error":"invalid or missing field"}` |

## Request views & low-level response staging (`honk::Ctx&`)

| Signature | Notes |
|---|---|
| `ctx.method`, `.path`, `.query_str`, `.body`, `.hdrs`, `.tail`, `.keep_alive`, `.head_only`, `.fd`, `.handled`, `.path_matched` | Request views into `rx_buf` + routing flags |
| `ctx.header(name) -> val, bool` | Case-insensitive, OWS-trimmed scan |
| `ctx.query(key) -> val, bool` | Raw `k=v&` scan, first wins, no decoding |
| `ctx.query_str_or(key, default) -> val` | Default when absent |
| `ctx.query_int_or(key, default: i64) -> i64` | Default when absent/invalid/overflowing |
| `ctx.query_decoded(key) -> val, bool` | `%XX` + `+`→space via `ctx.tmp`; zero-copy when clean |
| `ctx.param_str(i) -> val` / `ctx.param_int(i) -> i64, bool` / `ctx.param_decoded(i) -> val, bool` | Indexed param helpers |
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
| `app.static_dir(prefix, root)` | Mount `root` directory for `GET`/`HEAD` (`index.html` resolution + `405` tracking) |
| `try_serve_file(ctx, root, with_index) -> bool` | Low-level `GET`/`HEAD` handler (`true` = `200`/`HEAD`/`405` staged; `false` = miss/rejected) |
| `serve_rel(ctx, root, rel, with_index) -> bool` | Serve an explicit relative path (e.g. SPA `"index.html"` fallback) |
| `mime_for_rel(rel) -> ctype` | Extension MIME lookup (14 web types, else `application/octet-stream`) |

## SQLite (`import honk_sqlite from "<honk>/sqlite";`, opt-in `-lsqlite3`)

| Signature | Notes |
|---|---|
| `db_connect(path, schema = "") -> Db` | Open + enable WAL/`busy_timeout`/`foreign_keys` + run optional DDL (aborts on setup error) |
| `app.sql_json(db, sql)` | `SELECT` → `200` JSON array (`[]` when empty; `BOOLEAN`/`BOOL` columns emit `true`/`false`; `500` on error) |
| `app.sql_json_one(db, sql, id: i64)` | `SELECT … WHERE id = ?1` → `200` JSON object, `404` when empty, `500` on error |
| `app.sql_json_one_text(db, sql, val)` | Single `TEXT`-param variant of `sql_json_one` (`TRANSIENT` bind) |
| `insert_text(db, sql, text) -> id: i64, bool` | Parameterized 1-text `INSERT` returning `last_insert_rowid()` |
| `run_int(db, sql, id: i64) -> changes: i64, bool` | Parameterized 1-int `UPDATE`/`DELETE` returning affected row count |
| `struct Db { h }`, `struct Stmt { h }` | Opaque handles; one `Db` per worker |
| `db_open(path) -> Db, bool` / `db_enable_wal(db) -> bool` / `db_exec(db, sql) -> bool` | Low-level open / PRAGMAs / DDL |
| `db_close(db) -> bool` / `db_shutdown() -> bool` | Close worker handle / release global SQLite state |
| `db_prepare(db, sql) -> Stmt, bool` / `stmt_finalize(st) -> bool` | Reusable prepared statements |
| `stmt_step(st) -> i32` / `stmt_reset(st) -> bool` | Step (`ROW = 100`, `DONE = 101`) / reset + clear bindings |
| `bind_int/bind_float/bind_text/bind_text_static/bind_null(st, idx, …) -> bool` | 1-based parameter binding |
| `col_int/col_float/col_is_null(st, idx)` / `col_text(st, idx, out) -> slice, bool` / `col_name(st, idx, out) -> slice, bool` | 0-based column readers |
| `db_last_id(db) -> i64` / `db_changes(db) -> i64` | Last rowid / changed rows |

## Low-level transport (`honk_net`, rarely needed in apps)

`honk_worker_init/shutdown`, `honk_fork_workers/fork_env/fork_join`, `honk_wait`,
`honk_conn_read`, `honk_parse_req`, `honk_send`, `honk_sendfile_data`,
`honk_conn_finish`, `honk_close`, `honk_pin_thread_cpu`, `honk_set_timeouts`,
telemetry (`honk_worker_id`, `honk_active_conns`, `honk_accepted_total`,
`honk_rejected_conns`, `honk_timed_out_conns`, `honk_tx_queued_count`),
`honk_shrink_sndbuf`, `honk_debug_stack_top/base`, `RawReq`, `write_response`,
`write_error_response`.
