# Honk API Reference

All application-facing functions. `honk_ctx` helpers are free functions called
with method syntax (`ctx.text(...)`) via UFCS; `honk::` names live in
`src/honk_serve/honk_serve.goose`. Everything below is `inline` except where
noted (`header`, `query`, `cookie`, `parse_*`, `status_text`, `emit`,
`listen_*`) — unused helpers compile away; hot-path calls inline into the
worker loop.

Conventions: `const u8[:]` = zero-copy read-only view (never allocate); `bool`
second return = `ok` (check it); `ctx.res` = response builder, `ctx.tmp` =
decode/scratch space, `ctx.dom`/`ctx.dstr` = JSON DOM workspace.

## Server runner (`honk::`)

| Signature | Notes |
|---|---|
| `struct Config { port, idle_ms = 30000, header_ms = 10000, worker_id = 0, cpu_id = -1 }` | `-1` = no pinning |
| `honk::listen_or_abort(port: i32)` | Default timeouts, no pin; aborts w/ message on failure |
| `honk::listen_cfg_or_abort(cfg: Config&)` | Full config; aborts on failure |
| `honk::serve() { fd, date => … };` | `inline` epoll loop; stops + shuts down cleanly on `honk_request_stop()` |
| `honk::request(fd, date) { ctx => … };` | `inline` turn: recv → pipelined requests → send; default `404` when unstaged; closes on `!keep_alive` or protocol error |
| `honk_request_stop()` | Ask *this* worker to exit its loop (route-triggered shutdown) |
| `honk_should_stop() -> i32` | `1` once stop was requested |

## Request views (`Ctx&` first arg)

| Signature | Notes |
|---|---|
| `ctx.method`, `.path` (query stripped), `.query_str`, `.body`, `.hdrs`, `.keep_alive`, `.head_only`, `.fd` | Fields; views into `rx_buf` |
| `ctx.header(name) -> val, bool` | Case-insensitive, trimmed, `O(headers)` scan |
| `ctx.query(key) -> val, bool` | Raw `k=v&` scan, first wins, no decoding |
| `ctx.query_str_or(key, default) -> val` | Default when absent |
| `ctx.query_int_or(key, default: i64) -> i64` | Default when absent/invalid/overflowing |
| `ctx.query_decoded(key) -> val, bool` | `%XX` + `+`→space via `ctx.tmp`; zero-copy when clean; `false` when absent/malformed |
| `ctx.param_str(i) -> val` | `params[i]` or `""` |
| `ctx.param_int(i) -> i64, bool` | Strict `i64` (sign + digits + range) |
| `ctx.param_decoded(i) -> val, bool` | `%XX` via `ctx.tmp` (`+` stays literal); `false` when absent/malformed |
| `ctx.rest(prefix) -> rest, bool` | Wildcard: non-empty remainder (may contain `/`) |
| `rest.has_dotdot() -> bool` | `true` on any `..` segment |
| `match_1param(path, prefix) -> seg, bool` | Free fn: single non-empty `/`-free segment |
| `parse_i64_strict(s) -> i64, bool` | Free fn: the strict integer grammar |
| `ctx.bearer_token() -> token, bool` | `Authorization: Bearer …`, scheme case-insensitive |
| `ctx.cookie(name) -> val, bool` | `Cookie` header lookup, OWS-tolerant |

## Response staging (`Ctx&` first arg; all set `responded`)

| Signature | Notes |
|---|---|
| `ctx.text(status, s)` | `text/plain` |
| `ctx.html(status, s)` | `text/html` |
| `ctx.bytes(status, s)` | `application/octet-stream` |
| `ctx.json_raw(status, s)` | `application/json`, pre-serialized slice |
| `ctx.json_error(code, msg)` | Builds `{"error":"…"}` (escaped) into `ctx.res` |
| `ctx.no_content()` | Empty `204` |
| `ctx.redirect(location, code = 302)` | `Location` header + empty body |
| `ctx.set_header(name, val)` | Max 8 extras; beyond dropped |
| `ctx.set_cookie(name, val, opts = "")` | Builds `name=val[; opts]` into `ctx.tmp`, stages `Set-Cookie` |
| `ctx.cors_allow_all()` | `*` origin + methods + headers |
| `ctx.cors_with_origin(origin)` | Fixed origin variant |
| `ctx.cors_preflight()` | Allow-all headers + empty `204` |
| `status_text(code) -> phrase` | Free fn: 200/201/204/301/302/303/307/308/400/401/403/404/405/422, else `Internal Server Error` |
| `ctx.emit(out, date)` | The one framing site (status, `Content-Type`, `Date`, extras, `Connection`, `Content-Length`, body; drops body on `HEAD`/`204`) |

## JSON (`json::` stdlib + `honk_json`)

| Signature | Notes |
|---|---|
| `json::reader(body) -> Reader` | Caller-owned cursor (borrow §9.2: keep it in the handler) |
| `json::each_member(r) { key => … };` / `json::each_element(r) { … };` | Blocks; nested OK; mutate outer struct from inside |
| `json::read_string(r, scratch) -> view` | Zero-copy unless escaped (then into `scratch`) |
| `json::read_int/read_number/read_bool(r)` | Strict typed reads; sticky errors |
| `json::skip(r)` | Skip unknown keys/values (validates shape) |
| `json::finish(r) -> bool` | `false` on any error or trailing input — always check |
| `json::format_key/format_string/format_int/format_number/format_bool(out, …)` | In-place serialization into any `u8[>..]&` |
| `json::parse(text, doc, decoded) -> root?, err` | DOM tree into caller stacks; `member`/`as_*`/`each` to inspect |
| `honk_json`: `parse_typed_fields`, `emit_typed_post`, `parse_bench_user`, `emit_bench_created`, `emit_bench_msg`, `emit_bench_user`, `dom_summary`, `emit_dom_res`, `emit_hello_json` | Demo-app typed bindings/serializers (copy the pattern, don't reuse the demo structs) |

## Low-level (`honk_net`, rarely needed in apps)

`honk_worker_init/shutdown`, `honk_wait`, `honk_conn_read`, `honk_parse_req`,
`honk_send`, `honk_conn_finish`, `honk_close`, `honk_pin_thread_cpu`,
`honk_set_timeouts`, telemetry (`honk_worker_id/active_conns/accepted_total/
rejected_conns/timed_out_conns/tx_queued_count`), `honk_shrink_sndbuf`,
`honk_debug_stack_top/base`, `RawReq`, `write_response`, `write_error_response`.
Prefer `honk::serve/request`; touch these only for custom transports.
