# Honk API Reference

All application-facing modules and functions. Honk ships `honk.goose` +
`honk.build` at the repository root (with opt-in SQLite in `sqlite/` and
opt-in unit testing in `src/honk_test/`):

```goose
import honk from "ZeDoExter/Honk@v0.4.0";   // or relative "../Honk"
import honk_sqlite from "../Honk/sqlite";   // opt-in: SQLite (-lsqlite3)
import honk.src.honk_test.honk_test;        // opt-in: in-memory unit tester
```

Core types and server runners live in `namespace honk`; unused `inline fn`
helpers compile away completely so minimal binaries stay `~150 KiB`.

## Server runner & lifecycle (`honk::`)

| Signature | Notes |
|---|---|
| `honk::listen(port: i32) { app => … };` | 1 worker by default, or `$HONK_WORKERS` (`1..64` / `"auto"`) `SO_REUSEPORT` processes; auto `404`/`405`; drains up to `2s` on `SIGINT`/`SIGTERM` |
| `honk::listen_workers(port: i32, n: i32) { app => … };` | Explicit multi-worker `listen` (`0` = `sched_getaffinity` CPU count, `1..64`) |
| `honk::workers(n: i32) -> i32` / `honk::workers_env() -> i32` | Pre-`db_open()` worker fork (`0` = auto, `1..64`, or `$HONK_WORKERS`) |
| `honk::arg_port(default_port: i32) -> i32` | Reads `argv[1]` when in `1..65535`, else `default_port` |
| `app.group(prefix) { … };` | Nestable zero-alloc route prefix group (`"/api/v1"`); skips block in one branch when prefix misses |
| `app.cors()` / `app.cors(origin)` | One-line CORS headers + automatic `204` `OPTIONS` preflight (`handled = true`) |
| `app.bearer() { tok => … };` | Scoped Bearer auth guard; runs block on valid token, else stages `401` (`handled = true`) |
| `app.json_errors()` | Emits `application/json` `{"error":...}` for default `404` / `405` / `401` responses |
| `app.server_timing()` | Attaches `Server-Timing: honk;dur=<ms>.<us>` measured via `CLOCK_MONOTONIC` |
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
| `app.param(name) -> val` / `app.param(i: i64) -> val` | Zero-copy `:param` lookup by name (`app.param("id")`) or index (`app.param(0)`) |
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
| `app.body_str(key)` / `body_int(key)` / `body_bool(key)` | Memoized JSON DOM field readers (`val, bool`) |
| `app.require_str(key) { val => … };` | Non-empty string or `400 {"error":"invalid or missing field: <key>"}` |
| `app.require_str_len(key, min, max) { val => … };` | Bounded-length string or `400 {"error":"invalid length for field: <key>"}` |
| `app.require_int(key) { val => … };` | Integer field or `400 {"error":"invalid or missing field: <key>"}` |
| `app.require_int_range(key, min, max) { val => … };` | Bounded integer or `400 {"error":"out of range: <key>"}` |
| `app.require_bool(key) { val => … };` | Boolean field or `400 {"error":"invalid or missing field: <key>"}` |

## In-memory unit tester (`import honk.src.honk_test.honk_test;`)

| Signature | Notes |
|---|---|
| `honk::tester() -> Tester` | Value-owned test harness (zero sockets, reusable across thousands of requests) |
| `t.get(target) { app => … };` / `t.get_headers(target, hdrs) { app => … };` / `t.delete(target) { app => … };` | Synthetic `GET` / `DELETE` |
| `t.post_json` / `put_json` / `patch_json(target, json_body) { app => … };` | Synthetic JSON `POST` / `PUT` / `PATCH` |
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

## Static files (`honk_static`) & SQLite (`sqlite/honk_sqlite`)

- **Static**: `app.static_dir(prefix, root)`, `try_serve_file(ctx, root, with_index)`, `serve_rel(ctx, root, rel, with_index)`, `mime_for_rel(rel)`.
- **SQLite**: `db_connect(path, schema = "")`, `app.sql_json(db, sql)` (`BOOLEAN`/`BOOL` columns auto-emit `true`/`false`), `app.sql_json_one(db, sql, id)`, `app.sql_json_one_text(db, sql, val)`, `insert_text(db, sql, text)`, `run_int(db, sql, id)`, `db_open/db_enable_wal/db_exec/db_close/db_shutdown`, `db_prepare/stmt_finalize/stmt_step/stmt_reset`, `bind_int/float/text/text_static/null`, `col_int/float/is_null/text/name`, `db_last_id/db_changes`.
